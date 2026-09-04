<#
.SYNOPSIS
    Creates the toolkit tables, columns, choices, environment variables and security role
    in a development environment from schema.json.

.DESCRIPTION
    Run this once, in a development environment, to bootstrap the schema. Then export and
    unpack the solution into ./solution and commit it. From that point the pipeline packs
    the committed solution and this script is only needed when the schema changes.

    Do not run this against a client environment. Clients receive the managed solution.

    Safe to run repeatedly. Existing tables and columns are skipped, not overwritten, so a
    partial failure can be resumed by running it again.

.EXAMPLE
    ./New-Schema.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com -SolutionName PowerPeteIvrToolkitCore
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$SchemaFile = "$PSScriptRoot/schema.json",
    [string]$SolutionName = "PowerPeteIvrToolkitCore",
    [switch]$SkipSecurityRole
)

$ErrorActionPreference = "Stop"
$schema = Get-Content $SchemaFile -Raw | ConvertFrom-Json
$prefix = $schema.publisherPrefix
$orgUrl = $EnvironmentUrl.TrimEnd('/')

. "$PSScriptRoot/Common.ps1"

# No pac commands are used below. "pac env http" is not a real command in any published
# CLI version, so every metadata call goes straight to the Dataverse Web API with a token
# of its own. Common.ps1 caches that token, so the sign in prompt is a first run thing.
$accessToken = Get-DataverseToken -Resource $orgUrl

$baseHeaders = @{
    Authorization      = "Bearer $accessToken"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    Accept             = "application/json"
    "Content-Type"     = "application/json; charset=utf-8"
}

# MSCRM.SolutionUniqueName is only valid on calls that create a solution component.
# Sending it on an ordinary read fails the whole request, so it is added per call.
function Send-Metadata {
    param([string]$Method, [string]$Path, $Body, [int]$Attempts = 5)
    $uri = "$orgUrl$Path"
    $headers = $baseHeaders.Clone()
    $headers["MSCRM.SolutionUniqueName"] = $SolutionName

    for ($attempt = 1; ; $attempt++) {
        try {
            if ($Body) {
                return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body ($Body | ConvertTo-Json -Depth 15 -Compress)
            }
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
        }
        catch {
            $detail = $_.ErrorDetails.Message
            # A table created seconds ago is not in the metadata cache yet, so the first
            # thing that references it, a lookup above all, fails. It is a race, not a bad
            # request, so back off and try again rather than losing the whole run.
            if ($attempt -lt $Attempts -and $detail -match "MetadataCache") {
                Write-Host "         ... metadata cache catching up, retry $attempt" -ForegroundColor DarkGray
                Start-Sleep -Seconds (5 * $attempt)
                continue
            }
            throw "$Method $Path failed`n$detail"
        }
    }
}

function New-Label {
    param([string]$Text)
    return @{ LocalizedLabels = @(@{ Label = $Text; LanguageCode = 1033; "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel" }) }
}

function Test-TableExists {
    param([string]$LogicalName)
    try {
        Invoke-RestMethod -Method GET -Headers $baseHeaders `
            -Uri "$orgUrl/api/data/v9.2/EntityDefinitions(LogicalName='$LogicalName')?`$select=LogicalName" | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# Lookups create a relationship, and a second attempt fails on the navigation property
# name rather than being ignored. Checking first is what makes a re-run resumable.
function Test-ColumnExists {
    param([string]$Table, [string]$LogicalName)
    try {
        Invoke-RestMethod -Method GET -Headers $baseHeaders `
            -Uri "$orgUrl/api/data/v9.2/EntityDefinitions(LogicalName='$Table')/Attributes(LogicalName='$($LogicalName.ToLowerInvariant())')?`$select=LogicalName" | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Find-Record {
    param([string]$EntitySet, [string]$IdField, [string]$Filter)
    $uri = "$orgUrl/api/data/v9.2/$EntitySet" + '?$select=' + $IdField + '&$filter=' + $Filter
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $baseHeaders
    if ($resp.value.Count -gt 0) { return $resp.value[0].$IdField }
    return $null
}

function New-Record {
    param([string]$EntitySet, $Body)
    $uri = "$orgUrl/api/data/v9.2/$EntitySet"
    $headers = $baseHeaders.Clone()
    $headers["Prefer"] = "return=representation"
    try {
        return Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    catch {
        throw "POST /$EntitySet failed`n$($_.ErrorDetails.Message)"
    }
}

# --- Publisher and solution ---------------------------------------------------
# Every component below is filed into the solution named by MSCRM.SolutionUniqueName,
# and Dataverse rejects the call outright when that solution does not exist. Nothing
# else in the repo creates it, so bootstrapping it belongs here.
Write-Host "`nPublisher and solution" -ForegroundColor Cyan

$publisherUniqueName = if ($schema.publisherUniqueName) { $schema.publisherUniqueName } else { ($schema.publisherName -replace '\s', '').ToLowerInvariant() }
$optionValuePrefix = if ($schema.publisherOptionValuePrefix) { $schema.publisherOptionValuePrefix } else { 10000 }

$publisherId = Find-Record -EntitySet "publishers" -IdField "publisherid" -Filter "uniquename eq '$publisherUniqueName'"
if ($publisherId) {
    Write-Host "  = publisher $publisherUniqueName exists" -ForegroundColor DarkGray
}
else {
    $created = New-Record -EntitySet "publishers" -Body @{
        uniquename                     = $publisherUniqueName
        friendlyname                   = $schema.publisherName
        customizationprefix            = $prefix
        customizationoptionvalueprefix = $optionValuePrefix
    }
    $publisherId = $created.publisherid
    Write-Host "  + publisher $publisherUniqueName ($prefix)" -ForegroundColor DarkGray
}

$solutionId = Find-Record -EntitySet "solutions" -IdField "solutionid" -Filter "uniquename eq '$SolutionName'"
if ($solutionId) {
    Write-Host "  = solution $SolutionName exists" -ForegroundColor DarkGray
}
else {
    New-Record -EntitySet "solutions" -Body @{
        uniquename            = $SolutionName
        friendlyname          = if ($schema.solutionFriendlyName) { $schema.solutionFriendlyName } else { $SolutionName }
        version               = if ($schema.solutionVersion) { $schema.solutionVersion } else { "1.0.0.0" }
        "publisherid@odata.bind" = "/publishers($publisherId)"
    } | Out-Null
    Write-Host "  + solution $SolutionName" -ForegroundColor DarkGray
}

# --- Tables -------------------------------------------------------------------
$failures = @()

foreach ($table in $schema.tables) {
    if (Test-TableExists -LogicalName $table.logicalName) {
        Write-Host "[skip]   $($table.logicalName) already exists" -ForegroundColor DarkGray
    }
    else {
        Write-Host "[create] $($table.logicalName)" -ForegroundColor Cyan

        Send-Metadata -Method POST -Path "/api/data/v9.2/EntityDefinitions" -Body @{
            "@odata.type"          = "Microsoft.Dynamics.CRM.EntityMetadata"
            SchemaName             = $table.logicalName
            DisplayName            = (New-Label $table.displayName)
            DisplayCollectionName  = (New-Label $table.pluralName)
            Description            = (New-Label $table.description)
            OwnershipType          = "UserOwned"
            HasActivities          = $false
            HasNotes               = $false
            IsActivity             = $false
            Attributes             = @(@{
                "@odata.type"  = "Microsoft.Dynamics.CRM.StringAttributeMetadata"
                SchemaName     = $table.primaryField.name
                DisplayName    = (New-Label $table.primaryField.displayName)
                RequiredLevel  = @{ Value = "ApplicationRequired" }
                MaxLength      = $table.primaryField.maxLength
                FormatName     = @{ Value = "Text" }
                IsPrimaryName  = $true
            })
        } | Out-Null
    }

    # --- Columns --------------------------------------------------------------
    foreach ($column in $table.columns) {
        $path = "/api/data/v9.2/EntityDefinitions(LogicalName='$($table.logicalName)')/Attributes"
        $required = if ($column.required) { "ApplicationRequired" } else { "None" }

        if (Test-ColumnExists -Table $table.logicalName -LogicalName $column.name) {
            Write-Host "         = $($column.name) exists" -ForegroundColor DarkGray
            continue
        }

        $body = @{
            SchemaName    = $column.name
            DisplayName   = (New-Label $column.displayName)
            RequiredLevel = @{ Value = $required }
        }
        if ($column.description) { $body.Description = (New-Label $column.description) }

        # Lookups are relationships, not attributes, so they go to a different endpoint.
        # Handled before the switch because "continue" inside a PowerShell switch continues
        # the switch rather than the loop, which would fall through to the attribute POST.
        if ($column.type -eq "Lookup") {
            try {
                Send-Metadata -Method POST -Path "/api/data/v9.2/RelationshipDefinitions" -Body @{
                    "@odata.type"          = "Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata"
                    SchemaName             = "$($prefix)_$($column.target)_$($table.logicalName)_$($column.name)"
                    ReferencedEntity       = $column.target
                    ReferencingEntity      = $table.logicalName
                    CascadeConfiguration   = @{ Assign = "NoCascade"; Delete = "RemoveLink"; Merge = "NoCascade"; Reparent = "NoCascade"; Share = "NoCascade"; Unshare = "NoCascade" }
                    Lookup = @{
                        "@odata.type"  = "Microsoft.Dynamics.CRM.LookupAttributeMetadata"
                        SchemaName     = $column.name
                        DisplayName    = (New-Label $column.displayName)
                        RequiredLevel  = @{ Value = $required }
                    }
                } | Out-Null
                Write-Host "         + $($column.name) (lookup -> $($column.target))" -ForegroundColor DarkGray
            }
            catch {
                $reason = if ($_.Exception.Message -match '"message":\s*"([^"]+)"') { $Matches[1] } else { $_.Exception.Message }
                Write-Host "         ! $($column.name): $reason" -ForegroundColor Yellow
                $failures += "$($table.logicalName).$($column.name): $reason"
            }
            continue
        }

        switch ($column.type) {
            "String" {
                $body["@odata.type"] = "Microsoft.Dynamics.CRM.StringAttributeMetadata"
                $body.MaxLength = $column.maxLength
                $body.FormatName = @{ Value = "Text" }
            }
            "Memo" {
                $body["@odata.type"] = "Microsoft.Dynamics.CRM.MemoAttributeMetadata"
                $body.MaxLength = $column.maxLength
                $body.Format = "TextArea"
            }
            "Integer" {
                $body["@odata.type"] = "Microsoft.Dynamics.CRM.IntegerAttributeMetadata"
                $body.MinValue = if ($null -ne $column.minValue) { $column.minValue } else { 0 }
                $body.MaxValue = if ($null -ne $column.maxValue) { $column.maxValue } else { 1000000 }
                $body.Format = "None"
            }
            "Boolean" {
                $body["@odata.type"] = "Microsoft.Dynamics.CRM.BooleanAttributeMetadata"
                $body.DefaultValue = [bool]$column.defaultValue
                $body.OptionSet = @{
                    "@odata.type" = "Microsoft.Dynamics.CRM.BooleanOptionSetMetadata"
                    TrueOption    = @{ Value = 1; Label = (New-Label "Yes") }
                    FalseOption   = @{ Value = 0; Label = (New-Label "No") }
                }
            }
            "DateTime" {
                $body["@odata.type"] = "Microsoft.Dynamics.CRM.DateTimeAttributeMetadata"
                $body.Format = if ($column.format -eq "DateOnly") { "DateOnly" } else { "DateAndTime" }
                $body.DateTimeBehavior = @{ Value = if ($column.format -eq "DateOnly") { "DateOnly" } else { "UserLocal" } }
            }
            "Picklist" {
                $body["@odata.type"] = "Microsoft.Dynamics.CRM.PicklistAttributeMetadata"
                $body.OptionSet = @{
                    "@odata.type" = "Microsoft.Dynamics.CRM.OptionSetMetadata"
                    IsGlobal      = $false
                    OptionSetType = "Picklist"
                    Options       = @($column.options | ForEach-Object { @{ Value = $_.value; Label = (New-Label $_.label) } })
                }
                if ($null -ne $column.defaultValue) { $body.DefaultFormValue = $column.defaultValue }
            }
            default { throw "Unknown column type $($column.type) on $($column.name)" }
        }

        try {
            Send-Metadata -Method POST -Path $path -Body $body | Out-Null
            Write-Host "         + $($column.name)" -ForegroundColor DarkGray
        }
        catch {
            # Existing columns are filtered out above, so anything landing here is a real
            # failure. Collected rather than thrown so one bad column does not cost the run.
            $reason = if ($_.Exception.Message -match '"message":\s*"([^"]+)"') { $Matches[1] } else { $_.Exception.Message }
            Write-Host "         ! $($column.name): $reason" -ForegroundColor Yellow
            $failures += "$($table.logicalName).$($column.name): $reason"
        }
    }
}

# --- Environment variables ----------------------------------------------------
Write-Host "`nCreating environment variable definitions" -ForegroundColor Cyan
$typeCode = @{ "String" = 100000000; "Number" = 100000001; "Boolean" = 100000002; "JSON" = 100000003 }

foreach ($variable in $schema.environmentVariables) {
    try {
        Send-Metadata -Method POST -Path "/api/data/v9.2/environmentvariabledefinitions" -Body @{
            schemaname   = $variable.name
            displayname  = $variable.displayName
            type         = $typeCode[$variable.type]
            defaultvalue = $variable.default
        } | Out-Null
        Write-Host "  + $($variable.name)" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  = $($variable.name) exists" -ForegroundColor DarkGray
    }
}

# --- Security role ------------------------------------------------------------
if (-not $SkipSecurityRole) {
    Write-Host ""
    & "$PSScriptRoot/New-SecurityRole.ps1" -EnvironmentUrl $EnvironmentUrl -SchemaFile $SchemaFile -SolutionName $SolutionName
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) column(s) failed:" -ForegroundColor Yellow
    $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host "Fix the cause and run this script again. Existing components are skipped." -ForegroundColor Yellow
}

Write-Host "`nSchema created. Next:" -ForegroundColor Green
Write-Host "  1. Create the model driven app" -ForegroundColor Gray
Write-Host "  2. Add the plugin assembly to the solution" -ForegroundColor Gray
Write-Host "  3. pac solution export + unpack into ./solution, then commit" -ForegroundColor Gray
