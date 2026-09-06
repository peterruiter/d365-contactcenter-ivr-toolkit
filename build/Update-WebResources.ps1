<#
.SYNOPSIS
    Uploads the web resources from src/webresources and publishes them.

.DESCRIPTION
    The Settings page is source, in src/webresources/pwrp_settings.html, but it is not part
    of the packed solution: it is pushed through the Web API like every other component
    this repo creates. That left it deployed by New-ModelDrivenApp.ps1 alone, which is a
    script you run once when you install, so every deploy after that shipped a plugin
    update and left the page as it was on day one.

    A stale page is worse than an obviously missing one, because it works. A corrected
    query, a new setting, a better hint: none of it appears, and the page carries on
    behaving the way it did months ago while the source says otherwise.

    So deploy.ps1 calls this every run, and New-ModelDrivenApp.ps1 calls it too. Safe to
    run repeatedly and on its own.

.EXAMPLE
    ./Update-WebResources.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$SolutionName = "PowerPeteIvrToolkitCore",
    # Set when the caller has already connected, so this can be dot sourced into a script
    # that is midway through its own session rather than opening a second one.
    [switch]$SkipConnect
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Common.ps1"
if (-not $SkipConnect) { Connect-Dataverse -EnvironmentUrl $EnvironmentUrl }

# name, source, type. 1 is HTML, 11 is SVG.
$resources = @(
    @{ Name = "pwrp_settings"; Path = "$PSScriptRoot/../src/webresources/pwrp_settings.html"; Type = 1
       DisplayName = "Contact Center IVR Toolkit settings"
       Description = "Reads and writes the pwrp_ environment variables. Source is src/webresources/pwrp_settings.html." }
    @{ Name = "pwrp_/icons/ivrtoolkit.svg"; Path = "$PSScriptRoot/assets/app-icon.svg"; Type = 11
       DisplayName = "Contact Center IVR Toolkit icon"
       Description = "App tile icon. Source of truth is build/assets/app-icon.svg." }
)

Write-Host "Updating web resources" -ForegroundColor Cyan

$changed = @()

foreach ($resource in $resources) {
    if (-not (Test-Path $resource.Path)) { throw "Web resource source not found at $($resource.Path)." }

    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($resource.Path))
    $existing = (Invoke-Dataverse -Method GET -Path ("/api/data/v9.2/webresourceset" +
        "?`$select=webresourceid,content&`$filter=name eq '$($resource.Name)'")).value

    $body = @{
        name            = $resource.Name
        displayname     = $resource.DisplayName
        description     = $resource.Description
        webresourcetype = $resource.Type
        content         = $content
    }

    if ($existing.Count -eq 0) {
        Invoke-Dataverse -Method POST -Path "/api/data/v9.2/webresourceset" `
            -SolutionName $SolutionName -Body $body | Out-Null
        Write-Host "  + $($resource.Name)" -ForegroundColor Green
        $changed += $resource.Name
        continue
    }

    if ($existing[0].content -eq $content) {
        Write-Host "  = $($resource.Name), unchanged" -ForegroundColor DarkGray
        continue
    }

    Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/webresourceset($($existing[0].webresourceid))" `
        -SolutionName $SolutionName -Body $body | Out-Null
    Write-Host "  ~ $($resource.Name), updated" -ForegroundColor Yellow
    $changed += $resource.Name
}

# An uploaded web resource is not the served web resource until it is published, and
# nothing about the upload says so. This is the step whose absence looks exactly like a
# browser cache, and gets treated as one.
if ($changed.Count -gt 0) {
    $xml = "<importexportxml><webresources>" +
        (($changed | ForEach-Object { "<webresource>$_</webresource>" }) -join "") +
        "</webresources></importexportxml>"

    Invoke-Dataverse -Method POST -Path "/api/data/v9.2/PublishXml" `
        -Body @{ ParameterXml = $xml } -RetryOn "An unexpected error occurred" | Out-Null

    Write-Host "  published $($changed.Count)" -ForegroundColor Green
    Write-Host "  Hard refresh the Settings page, Ctrl+Shift+R, to get past the browser cache."
}
