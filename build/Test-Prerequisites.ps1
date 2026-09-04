<#
.SYNOPSIS
    Checks an environment is ready before you install.

.DESCRIPTION
    Confirms the tables the toolkit reads are present and readable. Run this first.
    Installing over a half provisioned Contact Center produces confusing errors later.

.EXAMPLE
    ./Test-Prerequisites.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl
)

$ErrorActionPreference = "Continue"

$required = @(
    @{ Table = "queues";                    Why = "Core queue metadata" }
    @{ Table = "msdyn_operatinghours";      Why = "Native opening hours. Optional if you use toolkit config hours" }
    @{ Table = "calendarrules";             Why = "Opening hours recurrence" }
    @{ Table = "msdyn_queueextensions";     Why = "Live queue metrics. Internal platform table" }
    @{ Table = "msdyn_ocliveworkitems";     Why = "Conversation state for metrics" }
    @{ Table = "msdyn_agentstatushistories"; Why = "Representative presence" }
    @{ Table = "msdyn_liveworkstreams";     Why = "Workstream lookup" }
)

& pac auth create --environment $EnvironmentUrl --name pwrp-prereq 2>$null
& pac auth select --name pwrp-prereq

$failures = 0
foreach ($check in $required) {
    try {
        & pac env http --method GET --url "/api/data/v9.2/$($check.Table)?`$top=1" | Out-Null
        Write-Host "[PASS] $($check.Table)" -ForegroundColor Green
    }
    catch {
        $failures++
        Write-Host "[FAIL] $($check.Table)" -ForegroundColor Red
        Write-Host "       $($check.Why)" -ForegroundColor Gray
    }
}

if ($failures -eq 0) {
    Write-Host "`nEnvironment ready. Run install.ps1" -ForegroundColor Green
    exit 0
}

Write-Host "`n$failures table(s) unavailable. Check Contact Center provisioning before installing." -ForegroundColor Red
Write-Host "See docs/02-prerequisites.md" -ForegroundColor Gray
exit 1
