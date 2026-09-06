<#
.SYNOPSIS
    Creates a pwrp_queueprofile row for every active queue that does not have one.

.DESCRIPTION
    Speeds up a first install. Defaults are conservative: native operating hours as
    the hours source, callback off, speakable name equal to the queue name. Review
    and adjust each profile afterwards, particularly the speakable name.

.EXAMPLE
    ./New-QueueProfiles.ps1 -EnvironmentUrl https://contoso.crm4.dynamics.com -All
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [switch]$All,
    [string]$ChannelType = "Voice"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

# Resolved rather than spelled out. Dataverse pluralises a schema name with a rule that
# turns pwrp_holiday into pwrp_holidaies, so a hardcoded set name is a guess.
$profileSet = Get-EntitySetName -LogicalName "pwrp_queueprofile"

$filter = if ($All) { "" } else { "&`$filter=msdyn_queuetype eq 192350002" }
$queues = (Invoke-Dataverse -Method GET -Path "/api/data/v9.2/queues?`$select=queueid,name$filter").value

Write-Host "Found $($queues.Count) queues" -ForegroundColor Cyan

foreach ($queue in $queues) {
    $existing = (Invoke-Dataverse -Method GET -Path "/api/data/v9.2/$profileSet?`$filter=_pwrp_queueid_value eq $($queue.queueid)").value
    if ($existing.Count -gt 0) {
        Write-Host "  skip $($queue.name), profile exists" -ForegroundColor Gray
        continue
    }

    Invoke-Dataverse -Method POST -Path "/api/data/v9.2/$profileSet" -Body @{
        pwrp_name                     = $queue.name
        pwrp_speakablename            = $queue.name
        pwrp_hourssource              = 1      # native operating hours
        pwrp_directcallbackenabled    = $false
        pwrp_scheduledcallbackenabled = $false
        pwrp_slotcapacity             = 5
        "pwrp_queueid@odata.bind"     = "/queues($($queue.queueid))"
    } | Out-Null

    Write-Host "  created profile for $($queue.name)" -ForegroundColor Green
}

Write-Host "Done. Review speakable names before going live." -ForegroundColor Green
