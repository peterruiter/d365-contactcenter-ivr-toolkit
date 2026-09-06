<#
.SYNOPSIS
    Calls the read only Custom APIs against a real queue and prints what comes back.

.DESCRIPTION
    Test-Installation.ps1 proves the plugin loads and the tables are readable. This proves
    the readers actually work, which is a different question: it exercises queue
    resolution, the native operating hours path and the metrics reader against live data.

    Nothing here writes. Callback creation and outcome logging are left out on purpose.

    Expect failures on first run against a new environment. The metrics reader in
    particular reads internal platform tables whose attribute names were never verified.
    A failure here is information, not a broken install.

.EXAMPLE
    ./Test-Endpoints.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com -Queue "HR"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$Queue,
    [string]$PhoneNumber = "0612345678",
    # Supply all three to run as the application user an agent authenticates as, which is
    # the only way to find out whether the minimal security role is sufficient.
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret
)

$ErrorActionPreference = "Continue"

. "$PSScriptRoot/Common.ps1"

if ($ClientId) {
    if (-not $TenantId -or -not $ClientSecret) { throw "Running as an application needs -TenantId, -ClientId and -ClientSecret." }
    Connect-DataverseAsApp -EnvironmentUrl $EnvironmentUrl -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    Write-Host "Running as the application user, so a failure here is a missing privilege." -ForegroundColor Yellow
}
else {
    Connect-Dataverse -EnvironmentUrl $EnvironmentUrl
}

$passed = 0
$failed = 0

<#
.SYNOPSIS
    Calls one unbound function and reports the outcome.
.DESCRIPTION
    Custom API functions are addressed with their parameters inline, and a string value has
    to be quoted. Errors are caught per call so one broken reader does not hide the rest.
#>
function Invoke-Endpoint {
    param([string]$Name, [string]$Api, $Body, [string[]]$Show)

    try {
        # Every endpoint is an action, so this is a POST with a body. They used to be
        # functions, called as GET pwrp_X(Queue='HR'), but the Dataverse connector only
        # offers actions and that is the route the toolkit tells people to use.
        $result = Invoke-Dataverse -Method POST -Path "/api/data/v9.2/$Api" -Body $Body
    }
    catch {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkGray
        $script:failed++
        return $null
    }

    # An expected failure returns HTTP 200 with Success false, by design. Treating a 200 as
    # a pass would report a broken reader as working, so Success is what decides here.
    if ($result.PSObject.Properties.Name -contains "Success" -and -not $result.Success) {
        Write-Host "[FAIL] $Name returned Success=false" -ForegroundColor Red
        Write-Host ("         {0,-24} {1}" -f "ErrorCode", $result.ErrorCode) -ForegroundColor DarkGray
        Write-Host ("         {0,-24} {1}" -f "ErrorMessage", $result.ErrorMessage) -ForegroundColor DarkGray
        $script:failed++
        return $result
    }

    Write-Host "[PASS] $Name" -ForegroundColor Green
    foreach ($field in ($Show + @("DurationMs") | Select-Object -Unique)) {
        $value = $result.$field
        if ($null -ne $value) {
            if ($value -is [string] -and $value.Length -gt 160) { $value = $value.Substring(0, 160) + "..." }
            Write-Host ("         {0,-24} {1}" -f $field, $value) -ForegroundColor Gray
        }
    }
    $script:passed++
    return $result
}

# --- Pick a queue -------------------------------------------------------------
if (-not $Queue) {
    $voice = (Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/queues?`$select=name&`$filter=statecode eq 0 and msdyn_queuetype eq 192350002&`$top=1").value
    if ($voice.Count -eq 0) { throw "No voice queues found. Pass -Queue explicitly." }
    $Queue = $voice[0].name
}

Write-Host "Testing against queue '$Queue'`n" -ForegroundColor Cyan

# --- Resolution ---------------------------------------------------------------
Invoke-Endpoint -Name "GetQueues" -Api "pwrp_GetQueues" -Body @{ ChannelType = "Voice" } `
    -Show @("Count", "Speakable") | Out-Null

Invoke-Endpoint -Name "ResolveQueue" -Api "pwrp_ResolveQueue" -Body @{ Queue = $Queue } `
    -Show @("QueueId", "QueueName", "SpeakableName", "ChannelType", "Locale") | Out-Null

# --- Hours. Exercises the native calendar path ---------------------------------
Invoke-Endpoint -Name "IsQueueOpen" -Api "pwrp_IsQueueOpen" -Body @{ Queue = $Queue } `
    -Show @("IsOpen", "Reason", "NextOpenUtc", "Speakable") | Out-Null

Invoke-Endpoint -Name "GetQueueHours" -Api "pwrp_GetQueueHours" -Body @{ Queue = $Queue; Days = 3 } `
    -Show @("Hours", "Speakable") | Out-Null

Invoke-Endpoint -Name "GetNextOpenTime" -Api "pwrp_GetNextOpenTime" -Body @{ Queue = $Queue } `
    -Show @("IsOpenNow", "NextOpenUtc", "Speakable") | Out-Null

# --- Metrics. The least verified reader in the toolkit -------------------------
Invoke-Endpoint -Name "GetQueueMetrics" -Api "pwrp_GetQueueMetrics" -Body @{ Queue = $Queue } `
    -Show @("WaitingNow", "LongestWaitSeconds", "AverageWaitSeconds", "EstimatedWaitSeconds",
            "RepresentativesAvailable", "RepresentativesOnline", "WaitBand", "Speakable") | Out-Null

# --- Composite. What an agent actually calls -----------------------------------
Invoke-Endpoint -Name "GetQueueContext" -Api "pwrp_GetQueueContext" -Body @{ Queue = $Queue } `
    -Show @("IsOpen", "WaitBand", "RecommendedAction", "Speakable") | Out-Null

# --- Utility ------------------------------------------------------------------
Invoke-Endpoint -Name "CheckCallbackEligibility" -Api "pwrp_CheckCallbackEligibility" -Body @{ Queue = $Queue } `
    -Show @("DirectCallbackAvailable", "ScheduledCallbackAvailable", "AnyAvailable") | Out-Null

Invoke-Endpoint -Name "GetBroadcastMessage" -Api "pwrp_GetBroadcastMessage" -Body @{ Queue = $Queue } `
    -Show @("HasMessage", "Speakable") | Out-Null

Invoke-Endpoint -Name "ValidatePhoneNumber" -Api "pwrp_ValidatePhoneNumber" -Body @{ PhoneNumber = $PhoneNumber } `
    -Show @("IsValid", "E164", "NumberType", "Speakable") | Out-Null

Write-Host "`n$passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
if ($failed -gt 0) {
    Write-Host "A failing reader is usually a wrong attribute name, not a broken install." -ForegroundColor Gray
    Write-Host "Every msdyn_ reference lives in Metrics/QueueMetricsReader.cs or" -ForegroundColor Gray
    Write-Host "Hours/OperatingHoursProvider.cs. Fix it there." -ForegroundColor Gray
}
