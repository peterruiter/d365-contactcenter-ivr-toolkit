<#
.SYNOPSIS
    Fills a development environment with believable sample data.

.DESCRIPTION
    Development environments only. This is sample content, not seed content: the aliases,
    the outage wording and the outcome history are all invented, and none of it belongs in
    a client environment. Seed-Data.ps1 is the one that loads real Dutch holidays and
    starter message templates.

    It exists so the model driven app has something in it, and so queue resolution can be
    tried against aliases rather than exact names, which is the path a caller actually
    takes.

    Safe to run repeatedly. Existing rows are matched on name and left alone.

.EXAMPLE
    ./New-DemoData.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [switch]$SkipOutcomes
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

function Add-Row {
    param([string]$EntitySet, [string]$NameField, [string]$Name, $Body)

    $escaped = $Name -replace "'", "''"
    $existing = (Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/$EntitySet`?`$select=$NameField&`$filter=$NameField eq '$escaped'").value
    if ($existing.Count -gt 0) {
        Write-Host "  = $Name" -ForegroundColor DarkGray
        return
    }

    $Body[$NameField] = $Name
    try {
        Invoke-Dataverse -Method POST -Path "/api/data/v9.2/$EntitySet" -Body $Body | Out-Null
        Write-Host "  + $Name" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  ! $Name : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- Queues to hang everything off --------------------------------------------
$queues = @{}
foreach ($q in (Invoke-Dataverse -Method GET `
    -Path "/api/data/v9.2/queues?`$select=queueid,name&`$filter=statecode eq 0 and msdyn_queuetype eq 192350002").value) {
    $queues[$q.name] = $q.queueid
}
Write-Host "Found $($queues.Count) voice queues" -ForegroundColor Cyan
if ($queues.Count -eq 0) { throw "No voice queues to attach sample data to." }

# --- Queue aliases ------------------------------------------------------------
# What a caller actually says, rather than what the queue is called. This is the highest
# return configuration in the toolkit, and the reason ResolveQueue exists.
Write-Host "`nQueue aliases" -ForegroundColor Cyan
$aliases = @(
    @{ Queue = "HR";                          Names = @("personeelszaken", "personeel", "human resources", "hr afdeling") }
    @{ Queue = "Accountant";                  Names = @("boekhouding", "financien", "administratie", "de boekhouder") }
    @{ Queue = "Contact center voice queue";  Names = @("klantenservice", "klanten service", "algemeen") }
    @{ Queue = "Set Up Pin Code";             Names = @("pincode", "pin code instellen", "code aanvragen") }
)

foreach ($entry in $aliases) {
    if (-not $queues.ContainsKey($entry.Queue)) {
        Write-Host "  skipped $($entry.Queue), no such queue here" -ForegroundColor DarkGray
        continue
    }
    foreach ($name in $entry.Names) {
        Add-Row -EntitySet "pwrp_queuealiases" -NameField "pwrp_name" -Name $name -Body @{
            "pwrp_queueid@odata.bind" = "/queues($($queues[$entry.Queue]))"
        }
    }
}

# --- Broadcast messages -------------------------------------------------------
# One live, one expired. The expired row is the point: it proves the active view filters,
# and a stale outage message is worse than none.
Write-Host "`nBroadcast messages" -ForegroundColor Cyan
$now = [DateTime]::UtcNow

Add-Row -EntitySet "pwrp_broadcastmessages" -NameField "pwrp_name" -Name "Storing telefonie (voorbeeld)" -Body @{
    pwrp_message   = "Op dit moment hebben we een storing in ons telefoniesysteem. U kunt ons bereiken via de chat op onze website. Onze excuses voor het ongemak."
    pwrp_validfrom = $now.AddHours(-1).ToString("o")
    pwrp_validto   = $now.AddDays(1).ToString("o")
}

Add-Row -EntitySet "pwrp_broadcastmessages" -NameField "pwrp_name" -Name "Onderhoud afgerond (verlopen voorbeeld)" -Body @{
    pwrp_message   = "Het onderhoud aan onze systemen is afgerond. Bedankt voor uw geduld."
    pwrp_validfrom = $now.AddDays(-7).ToString("o")
    pwrp_validto   = $now.AddDays(-6).ToString("o")
}

if ($queues.ContainsKey("HR")) {
    Add-Row -EntitySet "pwrp_broadcastmessages" -NameField "pwrp_name" -Name "HR drukte (voorbeeld)" -Body @{
        pwrp_message              = "Door drukte is de wachttijd bij personeelszaken op dit moment langer dan normaal."
        pwrp_validfrom            = $now.AddHours(-2).ToString("o")
        pwrp_validto              = $now.AddDays(2).ToString("o")
        "pwrp_queueid@odata.bind" = "/queues($($queues['HR']))"
    }
}

# --- IVR outcomes -------------------------------------------------------------
# Reporting has nothing to show until these exist, and docs/13-reporting.md is written
# against them. Spread over the last fortnight so a chart has a shape.
if (-not $SkipOutcomes) {
    Write-Host "`nIVR outcomes" -ForegroundColor Cyan
    $outcomes = @("Contained", "Contained", "Contained", "Escalated", "Escalated",
                  "CallbackBooked", "Abandoned", "ClosedAnnouncement")
    $intents = @("openingstijden", "wachttijd", "terugbelverzoek", "status aanvraag", "algemeen")
    $random = New-Object Random 20260904

    for ($i = 0; $i -lt 24; $i++) {
        $queueName = ($queues.Keys | Select-Object -First 1)
        $occurred = $now.AddDays(-$random.Next(0, 14)).AddMinutes(-$random.Next(0, 600))
        $outcome = $outcomes[$random.Next(0, $outcomes.Count)]

        Add-Row -EntitySet "pwrp_ivroutcomes" -NameField "pwrp_name" -Name "Voorbeeld gesprek $($i + 1)" -Body @{
            pwrp_outcome              = $outcome
            pwrp_intent               = $intents[$random.Next(0, $intents.Count)]
            pwrp_queuetext            = $queueName
            pwrp_agentname            = "Demo IVR agent"
            pwrp_durationseconds      = $random.Next(20, 240)
            pwrp_occurredon           = $occurred.ToString("o")
            "pwrp_queueid@odata.bind" = "/queues($($queues[$queueName]))"
        }
    }
}

Write-Host "`nSample data loaded." -ForegroundColor Green
Write-Host "Holidays and message templates come from Seed-Data.ps1, which loads real ones." -ForegroundColor Gray
