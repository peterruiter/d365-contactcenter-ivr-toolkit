<#
.SYNOPSIS
    Creates or updates Custom API metadata from customapis.json.

.DESCRIPTION
    Custom API definitions are data, not schema, so they live in customapis.json and are
    pushed by this script. That keeps the contract reviewable in a pull request instead of
    buried in solution XML.

    Safe to run repeatedly. Existing APIs are patched in place, which preserves the bindings
    any Copilot Studio agent already has.

    Run AFTER the assembly is in the environment, because each API binds to a plugin type
    resolved from it. That means after the solution import, or after Import-PluginAssembly.ps1
    when bootstrapping a development environment that has no solution to import yet.

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

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

function Send-Api {
    param([string]$Method, [string]$Path, $Body, [switch]$Representation)

    # WhatIf suppresses writes only. Reads still run, so a dry run can tell you which APIs
    # would be created against which plugin types rather than just echoing back the plan.
    if ($WhatIf -and $Method -ne "GET") {
        Write-Host "      WhatIf: $Method $Path" -ForegroundColor DarkGray
        return $null
    }

    if ($Method -eq "GET") { return Invoke-Dataverse -Method GET -Path $Path }
    return Invoke-Dataverse -Method $Method -Path $Path -Body $Body -SolutionName $solution -Representation:$Representation
}

<#
.SYNOPSIS
    Creates or updates one request parameter or response property.

.DESCRIPTION
    Two things about uniquename, both confirmed against a real environment on 2026-09-04.

    It is not an alternate key, so a child cannot be addressed as
    customapirequestparameters(uniquename='...'). That returns "The key in the request URI
    is not valid". Query by parent and name instead, then patch by id or create.

    It also becomes the property name in the generated message, so it has to be the bare
    name. An earlier version of this script wrote "<api>.<name>" to make the alternate key
    work, and the API then failed to execute at all with "property names must not contain
    any of the reserved characters ':', '.', '@'". Those rows are deleted and rewritten
    here, because uniquename cannot be patched.

    The parent binding and uniquename are only sent on create. Both are immutable.
#>
function Set-ApiChild {
    param(
        [string]$EntitySet,
        [string]$IdField,
        [string]$ApiName,
        [string]$ChildName,
        $Body
    )

    if ($WhatIf) {
        Write-Host "      WhatIf: upsert $EntitySet $ChildName on $ApiName" -ForegroundColor DarkGray
        return
    }

    $apiId = $script:apiIds[$ApiName]
    if (-not $apiId) { throw "No id known for $ApiName. It was neither found nor created." }

    $found = (Invoke-Dataverse -Method GET -Path ("/api/data/v9.2/$EntitySet" +
        "?`$select=$IdField,uniquename" +
        "&`$filter=_customapiid_value eq $apiId and (uniquename eq '$ChildName' or uniquename eq '$ApiName.$ChildName')")).value

    foreach ($stale in ($found | Where-Object { $_.uniquename -ne $ChildName })) {
        Invoke-Dataverse -Method DELETE -Path "/api/data/v9.2/$EntitySet($($stale.$IdField))" | Out-Null
        Write-Host "      - removed $($stale.uniquename)" -ForegroundColor DarkGray
    }

    $current = $found | Where-Object { $_.uniquename -eq $ChildName } | Select-Object -First 1
    if ($current) {
        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/$EntitySet($($current.$IdField))" `
            -Body $Body -SolutionName $solution | Out-Null
        return
    }

    $Body.uniquename = $ChildName
    $Body["CustomAPIId@odata.bind"] = "/customapis($apiId)"
    Invoke-Dataverse -Method POST -Path "/api/data/v9.2/$EntitySet" `
        -Body $Body -SolutionName $solution | Out-Null
}

# --- Validate the contract before touching the environment --------------------
# A parameter or property description over 100 characters is rejected, and the failure
# lands halfway through registration with some APIs updated and the rest not. Cheaper to
# find here.
$tooLong = @()
foreach ($api in $definition.apis) {
    foreach ($field in (@($api.inputs) + @($api.outputs) + @($definition.sharedOutputs))) {
        if ($field -and $field.description -and $field.description.Length -gt 100) {
            $tooLong += "$($api.name).$($field.name) is $($field.description.Length) characters"
        }
    }
}
if ($tooLong.Count -gt 0) {
    Write-Host "Descriptions over the 100 character limit:" -ForegroundColor Yellow
    $tooLong | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    throw "Shorten them in customapis.json. Nothing was registered."
}

# --- Resolve plugin type ids from the registered assembly ---------------------
Write-Host "Resolving plugin types from $($definition.assembly)" -ForegroundColor Cyan

$pluginTypes = @{}
$response = Send-Api -Method GET -Path "/api/data/v9.2/plugintypes?`$select=plugintypeid,typename&`$filter=startswith(typename,'PowerPete.IvrToolkit')"
foreach ($type in $response.value) { $pluginTypes[$type.typename] = $type.plugintypeid }

if ($pluginTypes.Count -eq 0 -and -not $WhatIf) {
    throw "No plugin types found. Import the solution with --activate-plugins before running this script."
}
Write-Host "  found $($pluginTypes.Count) plugin types" -ForegroundColor Gray

# --- Existing APIs, so we patch rather than duplicate -------------------------
$existing = @{}
$script:apiIds = @{}
$existingIsFunction = @{}
$current = Send-Api -Method GET -Path "/api/data/v9.2/customapis?`$select=customapiid,uniquename,isfunction&`$filter=startswith(uniquename,'$($definition.publisherPrefix)_')"
foreach ($api in $current.value) {
    $existing[$api.uniquename] = $api.customapiid
    $script:apiIds[$api.uniquename] = $api.customapiid
    $existingIsFunction[$api.uniquename] = [bool]$api.isfunction
}

# --- Push -------------------------------------------------------------------
Write-Host "`nRegistering $($definition.apis.Count) custom APIs into $solution" -ForegroundColor Cyan

foreach ($api in $definition.apis) {
    # Whether an API is a function or an action is fixed once it exists, and it decides how
    # the message is called: a function is a GET with the arguments in the URL, an action is
    # a POST with a body. Changing it means replacing the API, along with its parameters and
    # properties, which cascade with it.
    if ($existing.ContainsKey($api.name) -and $existingIsFunction[$api.name] -ne [bool]$api.isFunction) {
        $was = if ($existingIsFunction[$api.name]) { "function" } else { "action" }
        $now = if ($api.isFunction) { "function" } else { "action" }
        Write-Host "  [replace] $($api.name), $was becomes $now" -ForegroundColor Yellow
        if (-not $WhatIf) {
            Invoke-Dataverse -Method DELETE -Path "/api/data/v9.2/customapis($($existing[$api.name]))" | Out-Null
            $existing.Remove($api.name)
            $script:apiIds.Remove($api.name)
        }
    }

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
        $created = Send-Api -Method POST -Path "/api/data/v9.2/customapis" -Body $body -Representation
        if ($created) { $script:apiIds[$api.name] = $created.customapiid }
    }
    else {
        # Do not resend uniquename on a patch. It is immutable.
        $body.Remove("uniquename")
        Send-Api -Method PATCH -Path "/api/data/v9.2/customapis($($existing[$api.name]))" -Body $body | Out-Null
    }

    # Queried then created or patched, because uniquename is not an alternate key here.
    foreach ($parameter in $api.inputs) {
        Set-ApiChild -EntitySet "customapirequestparameters" -IdField "customapirequestparameterid" `
            -ApiName $api.name -ChildName $parameter.name -Body @{
                name        = $parameter.name
                displayname = $parameter.name
                description = $parameter.description
                type        = $typeMap[$parameter.type]
                isoptional  = -not [bool]$parameter.required
            }
    }

    foreach ($output in (@($api.outputs) + @($definition.sharedOutputs))) {
        Set-ApiChild -EntitySet "customapiresponseproperties" -IdField "customapiresponsepropertyid" `
            -ApiName $api.name -ChildName $output.name -Body @{
                name        = $output.name
                displayname = $output.name
                description = $output.description
                type        = $typeMap[$output.type]
            }
    }
}

Write-Host "`nCustom API registration complete." -ForegroundColor Green
Write-Host "Run Test-Installation.ps1 to validate." -ForegroundColor Gray
