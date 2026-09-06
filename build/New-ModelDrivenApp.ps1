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

# Settings are environment variables, and an administrator otherwise has to know that,
# then find them under the solution, which is not a place anyone looks.
#
# The obvious answer, a subarea over environmentvariabledefinition, is a bad screen and
# in some environments not even possible. Those are managed platform tables shared with
# every other solution, so the grid lists everyone's variables, and a filtered view is
# refused outright on the isparentcustomizable managed property. On top of that the
# definition and its value are two records, so changing a setting means editing a row in
# a second table that the first one only hints at.
#
# So this is a page instead: src/webresources/pwrp_settings.html. It reads the labels,
# guidance, types and defaults from the definitions and writes the values, and it can say
# whether a setting is on its default and put it back.
$settingsAreas = @(
    @{ WebResource = "pwrp_settings"; Title = "Settings"; Icon = "settings" }
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
Invoke-Dataverse -Method POST -Path "/api/data/v9.2/PublishXml" -RetryOn "An unexpected error occurred" -Body @{
    ParameterXml = "<importexportxml><appmodules><appmodule>$AppId</appmodule></appmodules></importexportxml>"
} | Out-Null

$app = Invoke-Dataverse -Method GET `
    -Path "/api/data/v9.2/appmodules($AppId)?`$select=appmoduleid,appmoduleidunique,name,uniquename"
Write-Host "  '$($app.name)' [$($app.uniquename)]" -ForegroundColor DarkGray

# --- App icon -----------------------------------------------------------------
# Without this the app shows the platform's default tile in the app selector, which is
# the same one several other apps use. The icon is an SVG web resource in this solution,
# so it travels with the export rather than being set by hand after every import.
#
# Line art in a single accent colour is not a style choice. The selector renders the tile
# on dark navy and the maker portal renders it on white, and a filled icon designed for
# one is unreadable on the other.
Write-Host "`nApp icon" -ForegroundColor Cyan

# Uploads only. Publishing happens once at the end, with the app and the sitemap: a web
# resource has to be published before anything can reference it, but publishing each one
# as it is uploaded means several publishes seconds apart, and the second of those came
# back "An unexpected error occurred" on an environment with other work in flight.
function Set-WebResource {
    param(
        [string]$Name,
        [string]$DisplayName,
        [string]$Description,
        [int]$Type,
        [string]$Path
    )

    if (-not (Test-Path $Path)) { throw "Web resource source not found at $Path." }

    $body = @{
        name            = $Name
        displayname     = $DisplayName
        description     = $Description
        webresourcetype = $Type
        content         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
    }

    $existing = (Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/webresourceset?`$select=webresourceid&`$filter=name eq '$Name'").value

    if ($existing.Count -gt 0) {
        $id = $existing[0].webresourceid
        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/webresourceset($id)" `
            -SolutionName $SolutionName -Body $body | Out-Null
        Write-Host "  = $Name" -ForegroundColor DarkGray
    }
    else {
        $id = (Invoke-Dataverse -Method POST -Path "/api/data/v9.2/webresourceset" `
            -SolutionName $SolutionName -Body $body).webresourceid
        Write-Host "  + $Name" -ForegroundColor DarkGray
    }

    return $id
}

$iconName = "pwrp_/icons/ivrtoolkit.svg"
$iconId = Set-WebResource -Name $iconName -Type 11 `
    -DisplayName "Contact Center IVR Toolkit icon" `
    -Description "App tile icon. Source of truth is build/assets/app-icon.svg." `
    -Path (Join-Path $PSScriptRoot "assets/app-icon.svg")

# The icon is a lookup, so it is set by binding rather than by writing the column, and
# the binding needs the navigation property name rather than the attribute name. The two
# are not the same here: "webresourceid@odata.bind" is rejected, because OData reads the
# annotation as belonging to a primitive property and fails inside the deserialiser with
# a stack trace that says nothing about lookups.
#
# Read the name rather than guessing it. Guessing produced that stack trace.
# appmodule.webresourceid is a Uniqueidentifier column, not a lookup. That is the whole
# story behind two earlier failures here: there is no relationship to find and no
# navigation property to bind through, so "webresourceid@odata.bind" was an annotation on
# a primitive, which fails inside the OData deserialiser with a stack trace that mentions
# neither lookups nor icons. Write the id.
try {
    Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/appmodules($AppId)" -SolutionName $SolutionName -Body @{
        webresourceid = $iconId
    } | Out-Null
    Write-Host "  + icon set on the app" -ForegroundColor DarkGray
}
catch {
    # Cosmetic, and the sitemap below is not, so this must not cost the run.
    Write-Warning ("Icon not set: $($_.Exception.Message)`n" +
        "Set it by hand in the app designer, choosing $iconName.")
}

# --- Settings page ------------------------------------------------------------
Write-Host "`nSettings page" -ForegroundColor Cyan

$settingsWebResource = "pwrp_settings"
$settingsId = Set-WebResource -Name $settingsWebResource -Type 1 `
    -DisplayName "Contact Center IVR Toolkit settings" `
    -Description "Reads and writes the pwrp_ environment variables. Source is src/webresources/pwrp_settings.html." `
    -Path (Join-Path $PSScriptRoot "../src/webresources/pwrp_settings.html")

# A subarea can point at a web resource the app does not list as a component, and it
# renders as an empty pane rather than an error. Adding it explicitly is what stops that.
try {
    Invoke-Dataverse -Method POST -Path "/api/data/v9.2/AddAppComponents" -Body @{
        AppId      = $AppId
        Components = @(@{ "@odata.type" = "Microsoft.Dynamics.CRM.webresource"; webresourceid = $settingsId })
    } | Out-Null
    Write-Host "  + added to the app" -ForegroundColor DarkGray
}
catch {
    Write-Warning "Settings page was not added to the app as a component: $($_.Exception.Message)"
}

# --- Sitemap ------------------------------------------------------------------
# Shape copied from a working app in the same organisation. The Client and Sku attributes
# are not decoration: a SubArea without them is dropped by the Unified Interface.
function New-SubArea {
    param($Area)

    if ($Area.WebResource) {
        # A web resource subarea is addressed by the $webresource: token, not by a path.
        # PassParams hands the page the organisation and user context in the query string.
        # AvailableOffline is false because the page calls the Web API on load.
        $target = "Url=`"`$webresource:$($Area.WebResource)`" AvailableOffline=`"false`" PassParams=`"true`""
        $suffix = $Area.WebResource -replace '^pwrp_', ''
    }
    else {
        $target = "Entity=`"$($Area.Entity)`" AvailableOffline=`"true`" PassParams=`"false`""
        $suffix = $Area.Entity -replace '^pwrp_', ''
    }

    return "<SubArea Id=`"pwrp_sub_$suffix`" VectorIcon=`"/_imgs/TableIconsFluentV9/$($Area.Icon).svg`" " +
        "Icon=`"/_imgs/imagestrips/transparent_spacer.gif`" " +
        "Client=`"All,Outlook,OutlookLaptopClient,OutlookWorkstationClient,Web`" " +
        "$target Sku=`"All,OnPremise,Live,SPLA`">" +
        "<Titles><Title LCID=`"1033`" Title=`"$($Area.Title)`" /></Titles></SubArea>"
}

$subAreas = ($areas | ForEach-Object { New-SubArea -Area $_ }) -join ""
$settingsSubAreas = ($settingsAreas | ForEach-Object { New-SubArea -Area $_ }) -join ""

$sitemapXml = "<SiteMap IntroducedVersion=`"7.0.0.0`">" +
    "<Area Id=`"pwrp_area_ivrtoolkit`" ResourceId=`"SitemapDesigner.NewTitle`" " +
    "DescriptionResourceId=`"SitemapDesigner.NewTitle`" ShowGroups=`"true`" IntroducedVersion=`"7.0.0.0`">" +
    "<Titles><Title LCID=`"1033`" Title=`"IVR toolkit`" /></Titles>" +
    "<Group Id=`"pwrp_group_ivrtoolkit`" ResourceId=`"SitemapDesigner.NewGroup`" " +
    "DescriptionResourceId=`"SitemapDesigner.NewGroup`" IntroducedVersion=`"7.0.0.0`" IsProfile=`"false`" " +
    "ToolTipResourseId=`"SitemapDesigner.Unknown`">" +
    "<Titles><Title LCID=`"1033`" Title=`"Configuration`" /></Titles>" +
    $subAreas +
    "</Group>" +
    "<Group Id=`"pwrp_group_settings`" ResourceId=`"SitemapDesigner.NewGroup`" " +
    "DescriptionResourceId=`"SitemapDesigner.NewGroup`" IntroducedVersion=`"7.0.0.0`" IsProfile=`"false`" " +
    "ToolTipResourseId=`"SitemapDesigner.Unknown`">" +
    "<Titles><Title LCID=`"1033`" Title=`"Settings`" /></Titles>" +
    $settingsSubAreas +
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

Write-Host "+ sitemap written, $($areas.Count + $settingsAreas.Count) areas" -ForegroundColor DarkGray
foreach ($area in ($areas + $settingsAreas)) { Write-Host "    $($area.Title)" -ForegroundColor DarkGray }

# --- Publish ------------------------------------------------------------------
# An unpublished sitemap is invisible, so this is part of creating the app rather than
# an optional extra.
Write-Host "`nPublishing" -ForegroundColor Cyan
Invoke-Dataverse -Method POST -Path "/api/data/v9.2/PublishXml" -RetryOn "An unexpected error occurred" -Body @{
    ParameterXml = "<importexportxml><appmodules><appmodule>$AppId</appmodule></appmodules>" +
                   "<sitemaps><sitemap>$sitemapId</sitemap></sitemaps>" +
                   "<webresources><webresource>$iconId</webresource>" +
                   "<webresource>$settingsId</webresource></webresources></importexportxml>"
} | Out-Null

Write-Host "`nApp ready. Open it from the Power Apps maker portal, or Dynamics 365 home." -ForegroundColor Green
Write-Host "Re-export the solution to commit it: ./build/Export-Solution.ps1" -ForegroundColor Gray
