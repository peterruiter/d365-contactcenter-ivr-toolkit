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

& pac auth create --environment $EnvironmentUrl --name pwrp-schema 2>$null
& pac auth select --name pwrp-schema

function Send-Metadata {
    param([string]$Method, [string]$Path, $Body)
    $args = @("env", "http", "--method", $Method, "--url", $Path,
              "--headers", "MSCRM.SolutionUniqueName=$SolutionName")
    if ($Body) { $args += @("--body", ($Body | ConvertTo-Json -Depth 15 -Compress)) }
    $raw = & pac @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$Method $Path failed`n$raw" }
    if ($raw) { try { return $raw | ConvertFrom-Json } catch { return $null } }
}

function New-Label {
    param([string]$Text)
    return @{ LocalizedLabels = @(@{ Label = $Text; LanguageCode = 1033; "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel" }) }
}

function Test-TableExists {
    param([string]$LogicalName)
    $raw = & pac env http --method GET --url "/api/data/v9.2/EntityDefinitions(LogicalName='$LogicalName')?`$select=LogicalName" 2>&1
    return $LASTEXITCODE -eq 0
}

# --- Tables -------------------------------------------------------------------
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

        $body = @{
            SchemaName    = $column.name
            DisplayName   = (New-Label $column.displayName)
            RequiredLevel = @{ Value = $required }
        }
        if ($column.description) { $body.Description = (New-Label $column.description) }

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
            "Lookup" {
                # Lookups are relationships, not attributes. Different endpoint.
                Write-Host "         lookup $($column.name) -> $($column.target)" -ForegroundColor DarkGray
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
                continue
            }
            default { throw "Unknown column type $($column.type) on $($column.name)" }
        }

        try {
            Send-Metadata -Method POST -Path $path -Body $body | Out-Null
            Write-Host "         + $($column.name)" -ForegroundColor DarkGray
        }
        catch {
            Write-Host "         = $($column.name) (exists or failed, see log)" -ForegroundColor DarkGray
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
    Write-Host "`nSecurity role" -ForegroundColor Cyan
    Write-Host @"
  Create the role '$($schema.securityRole.name)' manually, or with the Power Platform
  admin centre. Role privilege assignment through the Web API needs privilege ids that
  differ per environment, so scripting it is more fragile than doing it once by hand.

  Required privileges are listed in solution/README.md and schema.json.
  Do not substitute System Administrator.
"@ -ForegroundColor Yellow
}

Write-Host "`nSchema created. Next:" -ForegroundColor Green
Write-Host "  1. Create the security role and the model driven app" -ForegroundColor Gray
Write-Host "  2. Add the plugin assembly to the solution" -ForegroundColor Gray
Write-Host "  3. pac solution export + unpack into ./solution, then commit" -ForegroundColor Gray
