<#
.SYNOPSIS
    Reports what the platform actually thinks about each registered Custom API.

.DESCRIPTION
    Read only. Nothing here writes.

    Test-Installation.ps1 answers "does calling this work". This answers "why can something
    else not see it", which is a different question and the one that costs an afternoon.
    A Custom API can execute perfectly from a script while being invisible to the Dataverse
    connector, so a cloud flow or a custom connector cannot call it at all.

    Two rows govern that. The customapi row holds isprivate, and creating it generates an
    sdkmessage row that holds its own copy. The connector reads the message, not the API,
    so the two disagreeing is the failure worth catching. A private message is hidden from
    the metadata that connectors and code generation read.

    The connector also caches its message list per connection. If everything below is
    correct and the action is still missing from the designer's list, that cache is the
    remaining explanation, and recreating the connection clears it.

.EXAMPLE
    ./Get-ApiRegistration.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com

.EXAMPLE
    ./Get-ApiRegistration.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com -Name pwrp_PromoteDueCallbacks
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    # Report on one API instead of every one in the contract.
    [string]$Name,
    [string]$DefinitionFile = "$PSScriptRoot/customapis.json"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

$definition = Get-Content $DefinitionFile -Raw | ConvertFrom-Json
$wanted = if ($Name) { @($definition.apis | Where-Object { $_.name -eq $Name }) } else { $definition.apis }
if ($wanted.Count -eq 0) { throw "No API named $Name in $DefinitionFile." }

$rows = (Invoke-Dataverse -Method GET -Path ("/api/data/v9.2/customapis" +
    "?`$select=uniquename,isprivate,isfunction,bindingtype,executeprivilegename" +
    "&`$expand=SdkMessageId(`$select=name,isprivate,isactive)")).value

$byName = @{}
foreach ($row in $rows) { $byName[$row.uniquename] = $row }

$problems = 0

foreach ($api in $wanted) {
    $row = $byName[$api.name]

    if (-not $row) {
        Write-Host ("  ! {0}" -f $api.name) -ForegroundColor Red
        Write-Host "      not registered. Run Register-CustomApis.ps1." -ForegroundColor Red
        $problems++
        continue
    }

    # An API the contract calls internal is still an ordinary visible message. Internal is
    # a decision about what the connector and the MCP catalogue publish, and it is applied
    # when those are generated. It is not isprivate, and conflating the two stops the flows
    # that have to call these.
    $faults = @()
    if ($row.isprivate) { $faults += "customapi.isprivate is true" }
    if ($row.SdkMessageId -and $row.SdkMessageId.isprivate) { $faults += "sdkmessage.isprivate is true" }
    # isactive is deliberately not checked. It reads false on the generated message of every
    # custom API here, working ones included, so it says nothing about whether a message can
    # be called or seen. It looked like the answer once and cost a round trip.
    if ($row.bindingtype -ne 0) { $faults += "bindingtype is $($row.bindingtype), not Global" }
    if ($row.isfunction -ne [bool]$api.isFunction) { $faults += "isfunction is $($row.isfunction), contract says $([bool]$api.isFunction)" }
    if ($row.executeprivilegename) { $faults += "executeprivilegename is $($row.executeprivilegename)" }

    if ($faults.Count -eq 0) {
        Write-Host ("  + {0}" -f $api.name) -ForegroundColor Green
    }
    else {
        Write-Host ("  ! {0}" -f $api.name) -ForegroundColor Yellow
        foreach ($fault in $faults) { Write-Host "      $fault" -ForegroundColor Yellow }
        $problems++
    }
}

Write-Host ""
if ($problems -eq 0) {
    Write-Host "Every API is visible to connectors." -ForegroundColor Green
    Write-Host "An action still missing from a flow designer is the connector's own cache."
    Write-Host "Recreate the connection behind the connection reference to clear it."
}
else {
    Write-Host "$problems need attention." -ForegroundColor Yellow
    Write-Host "  customapi.isprivate    Register-CustomApis.ps1 clears it."
    Write-Host "  sdkmessage.isprivate   The message is not editable. Replace the API:"
    Write-Host "                         Register-CustomApis.ps1 -Recreate <name>"
    Write-Host "  isfunction, bindingtype  Fixed at creation. Same -Recreate."
}
