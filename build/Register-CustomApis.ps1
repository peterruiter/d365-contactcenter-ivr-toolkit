<#
.SYNOPSIS
    Creates or updates Custom API metadata from customapis.json.

.DESCRIPTION
    Custom API definitions are data, not schema, so they live in customapis.json and are
    pushed by this script. That keeps the contract reviewable in a pull request instead of
    buried in solution XML.

    Safe to run repeatedly. Existing APIs are patched in place, which preserves the bindings
    any Copilot Studio agent already has.

    Run AFTER the solution import, because the script resolves each plugin type id from the
    registered assembly.

.EXAMPLE
    ./Register-CustomApis.ps1 -EnvironmentUrl https://contoso.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$DefinitionFile = "$PSScriptRoot/customapis.json",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Custom API parameter type codes.
$typeMap = @{
    "Boolean" = 0; "DateTime" = 1; "Decimal" = 2; "Entity" = 3
    "EntityCollection" = 4; "EntityReference" = 5; "Float" = 6
    "Integer" = 7; "Money" = 8; "Picklist" = 9; "String" = 10
    "StringArray" = 11; "Guid" = 12
}

$definition = Get-Content $DefinitionFile -Raw | ConvertFrom-Json
$solution = $definition.solutionUniqueName

function Invoke-Dataverse {
    param([string]$Method, [string]$Path, $Body, [switch]$Quiet)

    if ($WhatIf) {
        Write-Host "      WhatIf: $Method $Path" -ForegroundColor DarkGray
        return $null
    }

    $args = @("env", "http", "--method", $Method, "--url", $Path)
    if ($Body) { $args += @("--body", ($Body | ConvertTo-Json -Depth 10 -Compress)) }
    if ($Method -ne "GET") { $args += @("--headers", "MSCRM.SolutionUniqueName=$solution") }

    $raw = & pac @args 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $Quiet) {
        throw "Dataverse call failed: $Method $Path`n$raw"
    }
    if ($raw) { try { return $raw | ConvertFrom-Json } catch { return $null } }
}

# --- Resolve plugin type ids from the registered assembly ---------------------
Write-Host "Resolving plugin types from $($definition.assembly)" -ForegroundColor Cyan

$pluginTypes = @{}
$response = Invoke-Dataverse -Method GET -Path "/api/data/v9.2/plugintypes?`$select=plugintypeid,typename&`$filter=startswith(typename,'PowerPete.IvrToolkit')"
foreach ($type in $response.value) { $pluginTypes[$type.typename] = $type.plugintypeid }

if ($pluginTypes.Count -eq 0 -and -not $WhatIf) {
    throw "No plugin types found. Import the solution with --activate-plugins before running this script."
}
Write-Host "  found $($pluginTypes.Count) plugin types" -ForegroundColor Gray

# --- Existing APIs, so we patch rather than duplicate -------------------------
$existing = @{}
$current = Invoke-Dataverse -Method GET -Path "/api/data/v9.2/customapis?`$select=customapiid,uniquename&`$filter=startswith(uniquename,'$($definition.publisherPrefix)_')"
foreach ($api in $current.value) { $existing[$api.uniquename] = $api.customapiid }

# --- Push -------------------------------------------------------------------
Write-Host "`nRegistering $($definition.apis.Count) custom APIs into $solution" -ForegroundColor Cyan

foreach ($api in $definition.apis) {
    $isNew = -not $existing.ContainsKey($api.name)
    $verb = if ($isNew) { "create" } else { "update" }
    Write-Host "  [$verb] $($api.name)" -ForegroundColor Gray

    if (-not $pluginTypes.ContainsKey($api.type) -and -not $WhatIf) {
        Write-Warning "    plugin type $($api.type) not registered, skipping"
        continue
    }

    $body = @{
        uniquename                      = $api.name
        name                            = $api.name
        displayname                     = $api.displayName
        description                     = $api.description
        bindingtype                     = 0        # Global. IVR calls are unbound.
        allowedcustomprocessingsteptype = 0        # None. Keep the surface tight.
        isfunction                      = [bool]$api.isFunction
        isprivate                       = [bool]$api.isPrivate
        workflowsdkstepenabled          = $false
        "PluginTypeId@odata.bind"       = "/plugintypes($($pluginTypes[$api.type]))"
    }

    if ($isNew) {
        Invoke-Dataverse -Method POST -Path "/api/data/v9.2/customapis" -Body $body | Out-Null
    }
    else {
        # Do not resend uniquename on a patch. It is immutable.
        $body.Remove("uniquename")
        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/customapis($($existing[$api.name]))" -Body $body | Out-Null
    }

    # Parameters are upserted by their alternate key, so reruns are safe.
    foreach ($input in $api.inputs) {
        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/customapirequestparameters(uniquename='$($api.name).$($input.name)')" -Body @{
            name                     = $input.name
            displayname              = $input.name
            description              = $input.description
            type                     = $typeMap[$input.type]
            isoptional               = -not [bool]$input.required
            "CustomAPIId@odata.bind" = "/customapis(uniquename='$($api.name)')"
        } | Out-Null
    }

    foreach ($output in (@($api.outputs) + @($definition.sharedOutputs))) {
        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/customapiresponseproperties(uniquename='$($api.name).$($output.name)')" -Body @{
            name                     = $output.name
            displayname              = $output.name
            description              = $output.description
            type                     = $typeMap[$output.type]
            "CustomAPIId@odata.bind" = "/customapis(uniquename='$($api.name)')"
        } | Out-Null
    }
}

Write-Host "`nCustom API registration complete." -ForegroundColor Green
Write-Host "Run Test-Installation.ps1 to validate." -ForegroundColor Gray
