<#
.SYNOPSIS
    Guided first time install. Start here.

.DESCRIPTION
    Walks a first time installer through prerequisites, import, configuration and
    validation. Prompts for the values that differ per client and writes them into
    environment variables so nothing client specific ends up in code.

.EXAMPLE
    ./install.ps1
#>
[CmdletBinding()]
param(
    [string]$EnvironmentUrl,
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"

Write-Host @"

Contact Center IVR Toolkit
Guided installation

This takes about 20 minutes. You need:
  - System Administrator on the target Dataverse environment
  - Dynamics 365 Contact Center provisioned with unified routing enabled
  - Power Platform CLI (pac) 1.30 or later

"@ -ForegroundColor Cyan

if (-not $EnvironmentUrl) {
    $EnvironmentUrl = Read-Host "Environment url (https://yourorg.crm4.dynamics.com)"
}

# --- Prerequisites -----------------------------------------------------------
Write-Host "`nStep 1 of 6: checking prerequisites" -ForegroundColor Cyan

$pac = Get-Command pac -ErrorAction SilentlyContinue
if (-not $pac) { throw "Power Platform CLI not found. Install it with: dotnet tool install --global Microsoft.PowerApps.CLI.Tool" }

. "$PSScriptRoot/Common.ps1"
Connect-Pac -EnvironmentUrl $EnvironmentUrl -ProfileName "pwrp-install"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

# --- Import ------------------------------------------------------------------
Write-Host "`nStep 2 of 6: importing the solution" -ForegroundColor Cyan
& "$PSScriptRoot/deploy.ps1" -EnvironmentUrl $EnvironmentUrl -Version $Version -Managed -SkipHealthCheck

# --- Configuration -----------------------------------------------------------
Write-Host "`nStep 3 of 6: configuration" -ForegroundColor Cyan

$locale = Read-Host "Default locale for spoken output [nl-NL]"
if (-not $locale) { $locale = "nl-NL" }

$timezone = Read-Host "Default time zone [W. Europe Standard Time]"
if (-not $timezone) { $timezone = "W. Europe Standard Time" }

$country = Read-Host "Default country calling code, digits only [31]"
if (-not $country) { $country = "31" }

$bands = Read-Host "Wait band thresholds in seconds, short/moderate/long [60,180,420]"
if (-not $bands) { $bands = "60,180,420" }

$scheduled = Read-Host "Enable scheduled callback? Requires an outbound workstream (y/N)"
$scheduledEnabled = $scheduled -eq "y"

$workstream = ""
if ($scheduledEnabled) {
    $workstream = Read-Host "Outbound workstream id (guid)"
}

$variables = @{
    "pwrp_DefaultLocale"           = $locale
    "pwrp_DefaultTimeZone"         = $timezone
    "pwrp_DefaultCountryCode"      = $country
    "pwrp_WaitBandThresholds"      = $bands
    "pwrp_MetricsCacheSeconds"     = "15"
    "pwrp_HoursCacheSeconds"       = "300"
    "pwrp_MetricsWindowMinutes"    = "60"
    "pwrp_EnableScheduledCallback" = $scheduledEnabled.ToString().ToLower()
    "pwrp_OutboundWorkstreamId"    = $workstream
    "pwrp_MaxCallbackAttempts"     = "3"
    "pwrp_CallbackRetryMinutes"    = "20"
    "pwrp_CallbackSlotMinutes"     = "30"
    "pwrp_TelemetryEnabled"        = "true"
}

foreach ($key in $variables.Keys) {
    if ($variables[$key]) {
        Write-Host "  setting $key" -ForegroundColor Gray
        Invoke-Dataverse -Method POST -Path "/api/data/v9.2/environmentvariablevalues" -Body @{
            value = $variables[$key]
            "EnvironmentVariableDefinitionId@odata.bind" = "/environmentvariabledefinitions(schemaname='$key')"
        } | Out-Null
    }
}

# --- Seed data ---------------------------------------------------------------
Write-Host "`nStep 4 of 6: holidays and message templates" -ForegroundColor Cyan
$seed = Read-Host "Load Dutch public holidays and nl-NL templates? (Y/n)"
if ($seed -ne "n") {
    & "$PSScriptRoot/Seed-Data.ps1" -EnvironmentUrl $EnvironmentUrl -Years 2
}

# --- Queue profiles ----------------------------------------------------------
Write-Host "`nStep 5 of 6: queue profiles" -ForegroundColor Cyan
Write-Host @"
Every queue the IVR touches needs a pwrp_queueprofile row. The toolkit works
without one, but you lose speakable names, per queue hours source and callback
settings.

Open the Contact Center IVR Toolkit app and create profiles now, or run:
  ./New-QueueProfiles.ps1 -EnvironmentUrl $EnvironmentUrl -All

"@ -ForegroundColor Yellow

# --- Validate ----------------------------------------------------------------
Write-Host "Step 6 of 6: validation" -ForegroundColor Cyan
& "$PSScriptRoot/Test-Installation.ps1" -EnvironmentUrl $EnvironmentUrl

Write-Host @"

Next: docs/06-copilot-studio.md wires the tools into your agent.
Start with pwrp_GetQueueContext. It is the only tool a real-time voice agent
needs at the start of a call.

"@ -ForegroundColor Green
