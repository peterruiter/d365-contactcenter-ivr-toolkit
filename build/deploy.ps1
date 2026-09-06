<#
.SYNOPSIS
    Deploys the toolkit to a Dataverse environment.

.DESCRIPTION
    First time installers should use install.ps1 instead, which wraps this with
    prompts and validation. This script assumes you know the environment url and
    have already authenticated with pac.

.EXAMPLE
    ./deploy.ps1 -EnvironmentUrl https://contoso.crm4.dynamics.com -Version 1.0.3 -Managed
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    # Defaults to whatever build.ps1 last produced, read from VERSION.
    [string]$Version,
    [switch]$Managed,
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = "Stop"
$type = if ($Managed) { "Managed" } else { "Unmanaged" }
if (-not $Version) {
    . "$PSScriptRoot/Version.ps1"
    $Version = (Get-ToolkitVersion -Root "$PSScriptRoot/..").Solution
}

$zip = "$PSScriptRoot/../out/PowerPeteIvrToolkitCore_$($Version)_$type.zip"

if (-not (Test-Path $zip)) { throw "Artefact not found: $zip. Run build.ps1 first." }

Write-Host "Connecting to $EnvironmentUrl" -ForegroundColor Cyan
. "$PSScriptRoot/Common.ps1"
Connect-Pac -EnvironmentUrl $EnvironmentUrl -ProfileName "pwrp-deploy"

Write-Host "Importing $type solution" -ForegroundColor Cyan
& pac solution import --path $zip --activate-plugins --force-overwrite --publish-changes
if ($LASTEXITCODE -ne 0) { throw "Solution import failed." }

Write-Host "Registering custom API metadata" -ForegroundColor Cyan
& "$PSScriptRoot/Register-CustomApis.ps1" -EnvironmentUrl $EnvironmentUrl

# The Settings page is source but not part of the packed solution, so importing the
# solution does not update it. Left to New-ModelDrivenApp.ps1, which is an install time
# script, it stayed as it was on day one while the source moved on for months.
& "$PSScriptRoot/Update-WebResources.ps1" -EnvironmentUrl $EnvironmentUrl

if (-not $SkipHealthCheck) {
    Write-Host "Running health check" -ForegroundColor Cyan
    & "$PSScriptRoot/Test-Installation.ps1" -EnvironmentUrl $EnvironmentUrl
}

Write-Host "Deployment complete." -ForegroundColor Green
