<#
.SYNOPSIS
    Loads Dutch public holidays and starter message templates.

.DESCRIPTION
    Run after the schema exists. Holidays are the thing nobody remembers to load, and
    they are the thing that makes the IVR say the wrong thing on Boxing Day.

    Loads two years by default. Set -Years to change.

.EXAMPLE
    ./Seed-Data.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com -Years 2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [int]$Years = 2,
    [switch]$SkipHolidays,
    [switch]$SkipTemplates
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

function Send-Record {
    param([string]$Path, $Body)
    # Seeding is idempotent by intent, not by constraint, so a duplicate is not fatal.
    try { Invoke-Dataverse -Method POST -Path $Path -Body $Body | Out-Null }
    catch { Write-Host "  = $($_.Exception.Message)" -ForegroundColor DarkGray }
}

# Easter drives four movable Dutch holidays. Anonymous Gregorian algorithm.
function Get-Easter {
    param([int]$Year)
    $a = $Year % 19; $b = [math]::Floor($Year / 100); $c = $Year % 100
    $d = [math]::Floor($b / 4); $e = $b % 4; $f = [math]::Floor(($b + 8) / 25)
    $g = [math]::Floor(($b - $f + 1) / 3); $h = (19 * $a + $b - $d - $g + 15) % 30
    $i = [math]::Floor($c / 4); $k = $c % 4
    $l = (32 + 2 * $e + 2 * $i - $h - $k) % 7
    $m = [math]::Floor(($a + 11 * $h + 22 * $l) / 451)
    $month = [math]::Floor(($h + $l - 7 * $m + 114) / 31)
    $day = (($h + $l - 7 * $m + 114) % 31) + 1
    return Get-Date -Year $Year -Month $month -Day $day -Hour 0 -Minute 0 -Second 0
}

if (-not $SkipHolidays) {
    $startYear = (Get-Date).Year
    Write-Host "Loading Dutch holidays for $startYear to $($startYear + $Years - 1)" -ForegroundColor Cyan

    for ($year = $startYear; $year -lt $startYear + $Years; $year++) {
        $easter = Get-Easter -Year $year

        $holidays = @(
            @{ Name = "Nieuwjaarsdag";      Date = (Get-Date -Year $year -Month 1  -Day 1) }
            @{ Name = "Goede Vrijdag";      Date = $easter.AddDays(-2) }
            @{ Name = "Eerste Paasdag";     Date = $easter }
            @{ Name = "Tweede Paasdag";     Date = $easter.AddDays(1) }
            @{ Name = "Koningsdag";         Date = (Get-Date -Year $year -Month 4  -Day 27) }
            @{ Name = "Hemelvaartsdag";     Date = $easter.AddDays(39) }
            @{ Name = "Eerste Pinksterdag"; Date = $easter.AddDays(49) }
            @{ Name = "Tweede Pinksterdag"; Date = $easter.AddDays(50) }
            @{ Name = "Eerste Kerstdag";    Date = (Get-Date -Year $year -Month 12 -Day 25) }
            @{ Name = "Tweede Kerstdag";    Date = (Get-Date -Year $year -Month 12 -Day 26) }
        )

        # Bevrijdingsdag is a public holiday every fifth year for most employers.
        if ($year % 5 -eq 0) {
            $holidays += @{ Name = "Bevrijdingsdag"; Date = (Get-Date -Year $year -Month 5 -Day 5) }
        }

        foreach ($holiday in $holidays) {
            # Koningsdag moves to the Saturday when it falls on a Sunday.
            $date = $holiday.Date
            if ($holiday.Name -eq "Koningsdag" -and $date.DayOfWeek -eq "Sunday") {
                $date = $date.AddDays(-1)
            }

            Send-Record -Path "/api/data/v9.2/pwrp_holidays" -Body @{
                pwrp_name = "$($holiday.Name) $year"
                pwrp_date = $date.ToString("yyyy-MM-dd")
            }
            Write-Host "  + $($holiday.Name) $year  $($date.ToString('ddd dd MMM'))" -ForegroundColor DarkGray
        }
    }

    Write-Host @"

  Loaded as closed-all-day, organisation wide.
  Adjust any the client actually works, and add Oudjaarsdag as a short day if they
  close early on 31 December. That one catches people out every year.
"@ -ForegroundColor Yellow
}

if (-not $SkipTemplates) {
    Write-Host "`nLoading message templates" -ForegroundColor Cyan

    # Every key the formatter understands, in both built in locales. Seeding all of them
    # means an administrator can see the whole vocabulary in the app and edit any phrase,
    # rather than guessing at key names that exist only in the source.
    #
    # These match the built in wording exactly, so seeding changes nothing until someone
    # edits a row. Placeholders are per key and are listed in docs/04-configuration.md.
    $templates = @(
        @{ Key = "open_now";          Locale = "nl-NL"; Text = "We zijn nu open tot {close}." }
        @{ Key = "closed_next";       Locale = "nl-NL"; Text = "We zijn nu gesloten. We zijn weer open {next}." }
        @{ Key = "closed_indefinite"; Locale = "nl-NL"; Text = "We zijn nu gesloten." }
        @{ Key = "holiday";           Locale = "nl-NL"; Text = "We zijn vandaag gesloten in verband met een feestdag." }
        @{ Key = "day_open";          Locale = "nl-NL"; Text = "{day} van {windows}" }
        @{ Key = "day_closed";        Locale = "nl-NL"; Text = "{day} gesloten" }
        @{ Key = "wait_short";        Locale = "nl-NL"; Text = "U wordt zo geholpen." }
        @{ Key = "wait_moderate";     Locale = "nl-NL"; Text = "De wachttijd is op dit moment een paar minuten." }
        @{ Key = "wait_long";         Locale = "nl-NL"; Text = "De wachttijd is op dit moment langer dan normaal." }
        @{ Key = "wait_verylong";     Locale = "nl-NL"; Text = "Het is nu erg druk en de wachttijd is lang." }
        @{ Key = "today";             Locale = "nl-NL"; Text = "vandaag" }
        @{ Key = "tomorrow";          Locale = "nl-NL"; Text = "morgen" }
        @{ Key = "at";                Locale = "nl-NL"; Text = "om" }
        @{ Key = "and";               Locale = "nl-NL"; Text = "en" }
        @{ Key = "callback_booked";   Locale = "nl-NL"; Text = "We bellen u terug {when} op {number}." }
        @{ Key = "callback_queued";   Locale = "nl-NL"; Text = "We bellen u terug op {number} zodra er een medewerker vrij is." }

        @{ Key = "open_now";          Locale = "en-GB"; Text = "We are open now until {close}." }
        @{ Key = "closed_next";       Locale = "en-GB"; Text = "We are closed right now. We open again {next}." }
        @{ Key = "closed_indefinite"; Locale = "en-GB"; Text = "We are closed right now." }
        @{ Key = "holiday";           Locale = "en-GB"; Text = "We are closed today for a public holiday." }
        @{ Key = "day_open";          Locale = "en-GB"; Text = "{day} from {windows}" }
        @{ Key = "day_closed";        Locale = "en-GB"; Text = "{day} closed" }
        @{ Key = "wait_short";        Locale = "en-GB"; Text = "You will be connected shortly." }
        @{ Key = "wait_moderate";     Locale = "en-GB"; Text = "The wait is a few minutes at the moment." }
        @{ Key = "wait_long";         Locale = "en-GB"; Text = "The wait is longer than usual at the moment." }
        @{ Key = "wait_verylong";     Locale = "en-GB"; Text = "It is very busy and the wait is long." }
        @{ Key = "today";             Locale = "en-GB"; Text = "today" }
        @{ Key = "tomorrow";          Locale = "en-GB"; Text = "tomorrow" }
        @{ Key = "at";                Locale = "en-GB"; Text = "at" }
        @{ Key = "and";               Locale = "en-GB"; Text = "and" }
        @{ Key = "callback_booked";   Locale = "en-GB"; Text = "We will call you back {when} on {number}." }
        @{ Key = "callback_queued";   Locale = "en-GB"; Text = "We will call you back on {number} as soon as someone is free." }
        @{ Key = "callback_slot";     Locale = "nl-NL"; Text = "{when}" }
        @{ Key = "callback_slot";     Locale = "en-GB"; Text = "{when}" }
    )

    foreach ($template in $templates) {
        # Existing rows are left alone, so a reseed never overwrites edited wording.
        $existing = (Invoke-Dataverse -Method GET -Path ("/api/data/v9.2/pwrp_messagetemplates" +
            "?`$select=pwrp_messagetemplateid&`$filter=pwrp_name eq '$($template.Key)' and pwrp_locale eq '$($template.Locale)'")).value
        if ($existing.Count -gt 0) {
            Write-Host "  = $($template.Key) $($template.Locale)" -ForegroundColor DarkGray
            continue
        }

        Send-Record -Path "/api/data/v9.2/pwrp_messagetemplates" -Body @{
            pwrp_name   = $template.Key
            pwrp_locale = $template.Locale
            pwrp_text   = $template.Text
        }
        Write-Host "  + $($template.Key) $($template.Locale)" -ForegroundColor DarkGray
    }
}

Write-Host "`nSeed complete." -ForegroundColor Green
Write-Host "Next: add queue aliases. That is the highest return configuration in the toolkit." -ForegroundColor Gray
