<#
.SYNOPSIS
    Runs pwrp_HealthCheck and prints the result.

.DESCRIPTION
    Run this after a first install, after every solution upgrade, and after any
    Dynamics 365 Contact Center release wave update. The metrics reader depends on
    internal platform tables, so a wave update is exactly when this catches something.

.EXAMPLE
    ./Test-Installation.ps1 -EnvironmentUrl https://contoso.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

$response = Invoke-Dataverse -Method GET -Path "/api/data/v9.2/pwrp_HealthCheck"
$checks = $response.Checks | ConvertFrom-Json

foreach ($check in $checks) {
    $symbol = if ($check.Passed) { "PASS" } else { "FAIL" }
    $colour = if ($check.Passed) { "Green" } else { "Red" }
    Write-Host ("[{0}] {1}" -f $symbol, $check.Check) -ForegroundColor $colour
    Write-Host ("       {0}" -f $check.Detail) -ForegroundColor Gray
}

if ($response.Passed) {
    Write-Host "`nInstallation healthy." -ForegroundColor Green
    exit 0
}

Write-Host "`n$($response.FailureCount) check(s) failed. See docs/09-troubleshooting.md" -ForegroundColor Red
exit 1
