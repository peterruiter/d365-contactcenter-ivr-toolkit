<#
.SYNOPSIS
    Exercises the callback and outcome logging endpoints, which write.

.DESCRIPTION
    Test-Endpoints.ps1 covers the read side. This covers the rest, and it creates real
    rows: a pwrp_callbackrequest and a pwrp_ivroutcome. Development environments only.

    The interesting assertion is the second CreateCallback. A voice agent retries on a
    timeout, so the same queue and number must return the existing request rather than a
    second one. That rule has never been tested anywhere else.

    Direct callback has to be enabled on the queue profile for any of this to run. Pass
    -EnableCallback to turn it on, which is itself a write.

.EXAMPLE
    ./Test-WritePaths.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com -Queue "HR" -EnableCallback
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$Queue,
    [string]$PhoneNumber = "0612345678",
    [switch]$EnableCallback
)

$ErrorActionPreference = "Continue"

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

$passed = 0
$failed = 0

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor Gray }
        $script:passed++
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
        $script:failed++
    }
}

<#
.SYNOPSIS
    Calls an endpoint and returns the result, or $null when it failed.
.DESCRIPTION
    Expected failures come back as HTTP 200 with Success false, so both shapes are
    folded into one "did it work" answer here.
#>
function Invoke-Api {
    param([string]$Method, [string]$Call, $Body)
    try {
        $result = Invoke-Dataverse -Method $Method -Path "/api/data/v9.2/$Call" -Body $Body
    }
    catch {
        Write-Host "         transport error: $($_.Exception.Message)" -ForegroundColor DarkGray
        return $null
    }
    if ($result.PSObject.Properties.Name -contains "Success" -and -not $result.Success) {
        Write-Host "         $($result.ErrorCode): $($result.ErrorMessage)" -ForegroundColor DarkGray
        return $null
    }
    return $result
}

if (-not $Queue) {
    $voice = (Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/queues?`$select=name&`$filter=statecode eq 0 and msdyn_queuetype eq 192350002&`$top=1").value
    if ($voice.Count -eq 0) { throw "No voice queues found. Pass -Queue explicitly." }
    $Queue = $voice[0].name
}

Write-Host "Writing against queue '$Queue' and number $PhoneNumber`n" -ForegroundColor Cyan

# --- Enable direct callback, if asked -----------------------------------------
if ($EnableCallback) {
    $resolved = Invoke-Api -Method POST -Call "pwrp_ResolveQueue" -Body @{ Queue = $Queue }
    if (-not $resolved) { throw "Could not resolve $Queue." }

    $queueProfile = (Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/pwrp_queueprofiles?`$select=pwrp_queueprofileid&`$filter=_pwrp_queueid_value eq $($resolved.QueueId)").value
    if ($queueProfile.Count -eq 0) { throw "No queue profile for $Queue. Run New-QueueProfiles.ps1." }

    Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/pwrp_queueprofiles($($queueProfile[0].pwrp_queueprofileid))" -Body @{
        pwrp_directcallbackenabled = $true
    } | Out-Null
    Write-Host "Direct callback enabled on the $Queue profile`n" -ForegroundColor Yellow
}

# --- Eligibility --------------------------------------------------------------
$eligibility = Invoke-Api -Method POST -Call "pwrp_CheckCallbackEligibility" -Body @{ Queue = $Queue }
Assert-That -Name "Direct callback is available" -Condition ($null -ne $eligibility -and $eligibility.DirectCallbackAvailable) `
    -Detail $(if ($eligibility) { "DirectCallbackAvailable=$($eligibility.DirectCallbackAvailable)" } else { "call failed" })

if (-not ($eligibility -and $eligibility.DirectCallbackAvailable)) {
    Write-Host "`nStopping. Re-run with -EnableCallback to turn it on for this queue." -ForegroundColor Yellow
    exit 1
}

# --- Create -------------------------------------------------------------------
$created = Invoke-Api -Method POST -Call "pwrp_CreateCallback" -Body @{
    Queue       = $Queue
    PhoneNumber = $PhoneNumber
    Mode        = "Direct"
    ContextJson = '{"source":"Test-WritePaths"}'
}
Assert-That -Name "CreateCallback returns a request" -Condition ($null -ne $created -and $created.CallbackId) `
    -Detail $(if ($created) { "id=$($created.CallbackId) reference=$($created.Reference) status=$($created.Status)" } else { "call failed" })

if (-not $created) { Write-Host "`nCannot continue without a callback." -ForegroundColor Yellow; exit 1 }

# The alphabet in CallbackService.NewReference, which drops anything that sounds or looks
# like something else over a phone line. Asserted against the real set rather than a guess
# at which characters those are: L is in it, O and I are not.
$alphabet = "3479ACEFHJKLMNPRTVWXY"
$strayCharacters = ($created.Reference.ToCharArray() | Where-Object { $alphabet.IndexOf($_) -lt 0 }) -join ""
Assert-That -Name "Reference uses only the speakable alphabet" `
    -Condition ($created.Reference.Length -eq 6 -and -not $strayCharacters) `
    -Detail "reference=$($created.Reference)$(if ($strayCharacters) { ", outside the alphabet: $strayCharacters" })"

# --- Idempotency, the rule that matters ---------------------------------------
$again = Invoke-Api -Method POST -Call "pwrp_CreateCallback" -Body @{
    Queue       = $Queue
    PhoneNumber = $PhoneNumber
    Mode        = "Direct"
}
Assert-That -Name "A repeat call returns the same request, not a second one" `
    -Condition ($null -ne $again -and $again.CallbackId -eq $created.CallbackId) `
    -Detail $(if ($again) { "first=$($created.CallbackId) second=$($again.CallbackId)" } else { "call failed" })

# --- Lookups ------------------------------------------------------------------
$byReference = Invoke-Api -Method POST -Call "pwrp_GetCallbackStatus" -Body @{ Reference = $created.Reference }
Assert-That -Name "GetCallbackStatus by reference" -Condition ($null -ne $byReference -and $byReference.Status) `
    -Detail $(if ($byReference) { "status=$($byReference.Status) attempts=$($byReference.Attempts)" } else { "call failed" })

$byPhone = Invoke-Api -Method POST -Call "pwrp_GetCallbackStatus" -Body @{ PhoneNumber = $PhoneNumber }
Assert-That -Name "GetCallbackStatus by phone number" -Condition ($null -ne $byPhone -and $byPhone.Status) `
    -Detail $(if ($byPhone) { "status=$($byPhone.Status)" } else { "call failed" })

# --- Cancel -------------------------------------------------------------------
$cancelled = Invoke-Api -Method POST -Call "pwrp_CancelCallback" -Body @{ CallbackId = $created.CallbackId }
Assert-That -Name "CancelCallback closes the request" -Condition ($null -ne $cancelled) `
    -Detail $(if ($cancelled) { "status=$($cancelled.Status)" } else { "call failed" })

# A cancelled request must not block a later one, or a caller who changed their mind
# could never book again.
$afterCancel = Invoke-Api -Method POST -Call "pwrp_CreateCallback" -Body @{
    Queue = $Queue; PhoneNumber = $PhoneNumber; Mode = "Direct"
}
Assert-That -Name "A cancelled request does not block a new one" `
    -Condition ($null -ne $afterCancel -and $afterCancel.CallbackId -ne $created.CallbackId) `
    -Detail $(if ($afterCancel) { "new id=$($afterCancel.CallbackId)" } else { "call failed" })

if ($afterCancel) {
    Invoke-Api -Method POST -Call "pwrp_CancelCallback" -Body @{ CallbackId = $afterCancel.CallbackId } | Out-Null
}

# --- Outcome logging ----------------------------------------------------------
$outcome = Invoke-Api -Method POST -Call "pwrp_LogIvrOutcome" -Body @{
    Outcome         = "CallbackBooked"
    Queue           = $Queue
    Intent          = "test"
    DurationSeconds = 42
    AgentName       = "Test-WritePaths"
}
Assert-That -Name "LogIvrOutcome records a row" -Condition ($null -ne $outcome -and $outcome.OutcomeId) `
    -Detail $(if ($outcome) { "id=$($outcome.OutcomeId)" } else { "call failed" })

Write-Host "`n$passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
Write-Host "Rows were created. Cancelled callbacks and one outcome row remain in the environment." -ForegroundColor Gray
