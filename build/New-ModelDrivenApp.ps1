<#
.SYNOPSIS
    Creates the Contact Center IVR Toolkit model driven app and its sitemap.

.DESCRIPTION
    The app is where an administrator publishes an outage message, which is the most time
    critical thing anyone does with this toolkit. docs/08-operations.md sends them to it by
    name, so it is part of the product rather than a convenience.

    The shell is created with "pac model create", which handles the app module record and
    its solution membership. The sitemap is then written here, because pac cannot express
    one. Sitemap order follows solution/README.md: the areas an administrator visits daily
    come first.

    Safe to run repeatedly. An existing app has its sitemap rewritten to match this file.

.EXAMPLE
    ./New-ModelDrivenApp.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$SolutionName = "PowerPeteIvrToolkitCore",
    [string]$AppName = "Contact Center IVR Toolkit",
    # Adopts an app that already exists, which is the way out if a previous run created one
    # and then failed. "pac model list" prints the id.
    [string]$AppId
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

# Order is the design. An administrator publishing an outage under pressure should find
# broadcast messages first, and the reference data they touch once a quarter last.
#
# Icons come from the platform's own /_imgs/TableIconsFluentV9 set, and every one below was
# checked to resolve against a real organisation before being used here. A path that does
# not resolve shows as a blank square rather than failing, so guessing is not safe. The
# usable set is small, which is why hours and holidays share the calendar.
#
# Do not substitute an icon from another solution's web resources. They resolve, but they
# make this solution depend on Field Service or Omnichannel being installed.
$areas = @(
    @{ Entity = "pwrp_broadcastmessage"; Title = "Broadcast messages"; Icon = "star" }
    @{ Entity = "pwrp_queuealias";       Title = "Queue aliases";      Icon = "link" }
    @{ Entity = "pwrp_callbackrequest";  Title = "Callback requests";  Icon = "approvals_app" }
    @{ Entity = "pwrp_queueprofile";     Title = "Queue profiles";     Icon = "settings" }
    @{ Entity = "pwrp_queuehours";       Title = "Queue hours";        Icon = "calendar_icon" }
    @{ Entity = "pwrp_holiday";          Title = "Holidays";           Icon = "calendar_icon" }
    @{ Entity = "pwrp_ivroutcome";       Title = "IVR outcomes";       Icon = "briefcase" }
    @{ Entity = "pwrp_messagetemplate";  Title = "Message templates";  Icon = "person" }
)

# --- App shell ----------------------------------------------------------------
# An app is matched on display name. "pac model create" invents its own unique name, so
# checking for one of ours by unique name would never match and every run would add
# another app.
if (-not $AppId) {
    $existing = (Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/appmodules?`$select=appmoduleid&`$filter=name eq '$AppName'").value
    if ($existing.Count -gt 0) {
        $AppId = $existing[0].appmoduleid
        Write-Host "= app '$AppName' exists" -ForegroundColor DarkGray
    }
}

if (-not $AppId) {
    Write-Host "Creating the app shell" -ForegroundColor Cyan
    Connect-Pac -EnvironmentUrl $EnvironmentUrl -ProfileName "pwrp-app"

    $output = & pac model create --name $AppName --solution $SolutionName `
        --description "Configuration and operations for the Contact Center IVR Toolkit." 2>&1
    $output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { throw "pac model create failed." }

    # The id has to come from pac's own output. A newly created app is unpublished, and an
    # unpublished app module is not returned by an ordinary Web API query, so looking it up
    # here finds nothing even though it exists.
    $match = [regex]::Match(($output | Out-String), 'App ID:\s*([0-9a-fA-F-]{36})')
    if (-not $match.Success) { throw "pac created the app but did not report an App ID to work with." }
    $AppId = $match.Groups[1].Value
    Write-Host "+ app created, id $AppId" -ForegroundColor DarkGray
}

# Publish before touching anything else, which is what makes the app and its sitemap
# readable through the Web API at all.
Write-Host "Publishing the app so it can be read" -ForegroundColor Cyan
Invoke-Dataverse -Method POST -Path "/api/data/v9.2/PublishXml" -Body @{
    ParameterXml = "<importexportxml><appmodules><appmodule>$AppId</appmodule></appmodules></importexportxml>"
} | Out-Null

$app = Invoke-Dataverse -Method GET `
    -Path "/api/data/v9.2/appmodules($AppId)?`$select=appmoduleid,appmoduleidunique,name,uniquename"
Write-Host "  '$($app.name)' [$($app.uniquename)]" -ForegroundColor DarkGray

# --- Sitemap ------------------------------------------------------------------
# Shape copied from a working app in the same organisation. The Client and Sku attributes
# are not decoration: a SubArea without them is dropped by the Unified Interface.
$subAreas = ($areas | ForEach-Object {
    $suffix = $_.Entity -replace '^pwrp_', ''
    "<SubArea Id=`"pwrp_sub_$suffix`" VectorIcon=`"/_imgs/TableIconsFluentV9/$($_.Icon).svg`" " +
    "Icon=`"/_imgs/imagestrips/transparent_spacer.gif`" " +
    "Entity=`"$($_.Entity)`" Client=`"All,Outlook,OutlookLaptopClient,OutlookWorkstationClient,Web`" " +
    "AvailableOffline=`"true`" PassParams=`"false`" Sku=`"All,OnPremise,Live,SPLA`">" +
    "<Titles><Title LCID=`"1033`" Title=`"$($_.Title)`" /></Titles></SubArea>"
}) -join ""

$sitemapXml = "<SiteMap IntroducedVersion=`"7.0.0.0`">" +
    "<Area Id=`"pwrp_area_ivrtoolkit`" ResourceId=`"SitemapDesigner.NewTitle`" " +
    "DescriptionResourceId=`"SitemapDesigner.NewTitle`" ShowGroups=`"true`" IntroducedVersion=`"7.0.0.0`">" +
    "<Titles><Title LCID=`"1033`" Title=`"IVR toolkit`" /></Titles>" +
    "<Group Id=`"pwrp_group_ivrtoolkit`" ResourceId=`"SitemapDesigner.NewGroup`" " +
    "DescriptionResourceId=`"SitemapDesigner.NewGroup`" IntroducedVersion=`"7.0.0.0`" IsProfile=`"false`" " +
    "ToolTipResourseId=`"SitemapDesigner.Unknown`">" +
    "<Titles><Title LCID=`"1033`" Title=`"Configuration`" /></Titles>" +
    $subAreas +
    "</Group></Area></SiteMap>"

$sitemapComponent = (Invoke-Dataverse -Method GET `
    -Path "/api/data/v9.2/appmodulecomponents?`$select=objectid&`$filter=_appmoduleidunique_value eq $($app.appmoduleidunique) and componenttype eq 62").value

if ($sitemapComponent.Count -eq 0) {
    throw "The app has no sitemap component. Nothing to write the navigation into."
}

$sitemapId = $sitemapComponent[0].objectid
Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/sitemaps($sitemapId)" -SolutionName $SolutionName -Body @{
    sitemapxml = $sitemapXml
} | Out-Null

Write-Host "+ sitemap written, $($areas.Count) areas" -ForegroundColor DarkGray
foreach ($area in $areas) { Write-Host "    $($area.Title)" -ForegroundColor DarkGray }

# --- Publish ------------------------------------------------------------------
# An unpublished sitemap is invisible, so this is part of creating the app rather than
# an optional extra.
Write-Host "`nPublishing" -ForegroundColor Cyan
Invoke-Dataverse -Method POST -Path "/api/data/v9.2/PublishXml" -Body @{
    ParameterXml = "<importexportxml><appmodules><appmodule>$AppId</appmodule></appmodules>" +
                   "<sitemaps><sitemap>$sitemapId</sitemap></sitemaps></importexportxml>"
} | Out-Null

Write-Host "`nApp ready. Open it from the Power Apps maker portal, or Dynamics 365 home." -ForegroundColor Green
Write-Host "Re-export the solution to commit it: ./build/Export-Solution.ps1" -ForegroundColor Gray
