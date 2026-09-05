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

# Settings sit in their own group. They are environment variables rather than toolkit
# tables, and an administrator otherwise has to find them under the solution, which is
# not a place anyone looks. The guidance for each one is its description, written by
# New-Schema.ps1 from schema.json, and it shows on the form.
$settingsAreas = @(
    @{ Entity = "environmentvariabledefinition"; Title = "Settings";        Icon = "settings" }
    @{ Entity = "environmentvariablevalue";      Title = "Setting values";  Icon = "briefcase" }
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

# --- App icon -----------------------------------------------------------------
# Without this the app shows the platform's default tile in the app selector, which is
# the same one several other apps use. The icon is an SVG web resource in this solution,
# so it travels with the export rather than being set by hand after every import.
#
# Line art in a single accent colour is not a style choice. The selector renders the tile
# on dark navy and the maker portal renders it on white, and a filled icon designed for
# one is unreadable on the other.
Write-Host "`nApp icon" -ForegroundColor Cyan

$iconPath = Join-Path $PSScriptRoot "assets/app-icon.svg"
if (-not (Test-Path $iconPath)) { throw "App icon not found at $iconPath." }

$iconName = "pwrp_/icons/ivrtoolkit.svg"
$iconContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($iconPath))

$iconBody = @{
    name           = $iconName
    displayname    = "Contact Center IVR Toolkit icon"
    description    = "App tile icon. Source of truth is build/assets/app-icon.svg."
    webresourcetype = 11   # SVG
    content        = $iconContent
}

$iconResource = (Invoke-Dataverse -Method GET `
    -Path "/api/data/v9.2/webresourceset?`$select=webresourceid&`$filter=name eq '$iconName'").value

if ($iconResource.Count -gt 0) {
    $iconId = $iconResource[0].webresourceid
    Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/webresourceset($iconId)" `
        -SolutionName $SolutionName -Body $iconBody | Out-Null
    Write-Host "  = web resource $iconName" -ForegroundColor DarkGray
}
else {
    $iconId = (Invoke-Dataverse -Method POST -Path "/api/data/v9.2/webresourceset" `
        -SolutionName $SolutionName -Body $iconBody).webresourceid
    Write-Host "  + web resource $iconName" -ForegroundColor DarkGray
}

# A web resource has to be published before anything can reference it. Setting the app
# icon to an unpublished resource leaves the tile blank rather than failing.
Invoke-Dataverse -Method POST -Path "/api/data/v9.2/PublishXml" -Body @{
    ParameterXml = "<importexportxml><webresources><webresource>$iconId</webresource></webresources></importexportxml>"
} | Out-Null

# The icon is a lookup, so it is set by binding rather than by writing the column, and
# the binding needs the navigation property name rather than the attribute name. The two
# are not the same here: "webresourceid@odata.bind" is rejected, because OData reads the
# annotation as belonging to a primitive property and fails inside the deserialiser with
# a stack trace that says nothing about lookups.
#
# Read the name rather than guessing it. Guessing produced that stack trace.
# The lookup is found by what it points at, not by its name. It is not called
# "webresourceid": filtering the relationships on that attribute name matched nothing,
# and an assumption about the name is what produced the deserialiser stack trace before
# that.
$iconLookup = (Invoke-Dataverse -Method GET -Path (
    "/api/data/v9.2/EntityDefinitions(LogicalName='appmodule')/Attributes/" +
    "Microsoft.Dynamics.CRM.LookupAttributeMetadata?`$select=LogicalName,Targets")).value |
    Where-Object { $_.Targets -contains "webresource" } |
    Select-Object -First 1

$iconNav = $null
if ($iconLookup) {
    $iconNav = ((Invoke-Dataverse -Method GET -Path (
        "/api/data/v9.2/EntityDefinitions(LogicalName='appmodule')/ManyToOneRelationships" +
        "?`$select=ReferencingAttribute,ReferencingEntityNavigationPropertyName" +
        "&`$filter=ReferencingAttribute eq '$($iconLookup.LogicalName)'")).value |
        Select-Object -First 1).ReferencingEntityNavigationPropertyName
}

# Not fatal. The icon is cosmetic, and the sitemap below is not, so a failure here must
# not cost the run. An earlier version threw at this point and never wrote the navigation.
if (-not $iconNav) {
    Write-Warning ("No appmodule lookup to webresource was found, so the icon was not set. " +
        "Set it by hand in the app designer, choosing $iconName.")
}
else {
    try {
        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/appmodules($AppId)" -SolutionName $SolutionName -Body @{
            "$iconNav@odata.bind" = "/webresourceset($iconId)"
        } | Out-Null
        Write-Host "  + icon set on the app via $iconNav" -ForegroundColor DarkGray
    }
    catch {
        Write-Warning ("Icon not set: $($_.Exception.Message)`n" +
            "Set it by hand in the app designer, choosing $iconName.")
    }
}

# --- Settings views -----------------------------------------------------------
# Both settings tables are platform tables shared with every other solution in the
# environment. Their stock views list every environment variable there is, so an
# administrator sent to "Settings" to change a wait threshold arrives at a list of
# other people's variables. These two views cut that down to pwrp_ only.
#
# The views are added to the app rather than made the table default. Changing the
# default would hide other solutions' variables from everyone, everywhere.
function Set-FilteredView {
    param(
        [string]$Entity,
        [string]$Name,
        [string]$Description,
        [string]$FetchXml,
        [string]$LayoutXml
    )

    # Both settings tables are managed system tables, and some environments will not
    # accept a new view on them at all: the create fails on the isparentcustomizable
    # managed property, after the row has been allocated an id, with a message about
    # component evaluation that does not mention views. CanCreateViews is the platform
    # saying so in advance, so ask first rather than reading it from a failure.
    $meta = Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/EntityDefinitions(LogicalName='$Entity')?`$select=ObjectTypeCode,CanCreateViews"

    if (-not $meta.CanCreateViews.Value) {
        Write-Warning ("'$Entity' does not allow new views in this environment, so '$Name' " +
            "was not created. Settings will list every environment variable rather than " +
            "only the toolkit's. Filter the grid on pwrp_ to narrow it.")
        return
    }

    # object= in the layout is the entity's type code. A wrong one is accepted on save
    # and then renders an empty grid, so it is read rather than guessed.
    $otc = $meta.ObjectTypeCode

    $existing = (Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/savedqueries?`$select=savedqueryid&`$filter=name eq '$Name' and returnedtypecode eq '$Entity'").value

    $body = @{
        name             = $Name
        description      = $Description
        returnedtypecode = $Entity
        fetchxml         = $FetchXml
        layoutxml        = $LayoutXml -replace 'OBJECTTYPECODE', $otc
        querytype        = 0
    }

    if ($existing.Count -gt 0) {
        $viewId = $existing[0].savedqueryid
        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/savedqueries($viewId)" `
            -SolutionName $SolutionName -Body $body | Out-Null
        Write-Host "  = view '$Name'" -ForegroundColor DarkGray
    }
    else {
        try {
            $viewId = (Invoke-Dataverse -Method POST -Path "/api/data/v9.2/savedqueries" `
                -SolutionName $SolutionName -Body $body).savedqueryid
            Write-Host "  + view '$Name'" -ForegroundColor DarkGray
        }
        catch {
            # Filtering the list is a convenience. The Settings navigation below is not,
            # so this warns rather than throwing.
            Write-Warning "View '$Name' was not created: $($_.Exception.Message)"
            return
        }
    }

    # Adding the view to the app is what puts it in the app's view picker. It is not
    # fatal when it fails: the view still exists and the table still opens.
    try {
        Invoke-Dataverse -Method POST -Path "/api/data/v9.2/AddAppComponents" -Body @{
            AppId      = $AppId
            Components = @(@{ "@odata.type" = "Microsoft.Dynamics.CRM.savedquery"; savedqueryid = $viewId })
        } | Out-Null
    }
    catch {
        Write-Warning "View '$Name' was not added to the app: $($_.Exception.Message)"
    }
}

Write-Host "`nFiltered settings views" -ForegroundColor Cyan

Set-FilteredView -Entity "environmentvariabledefinition" -Name "IVR toolkit settings" `
    -Description "Environment variables belonging to the Contact Center IVR Toolkit." `
    -FetchXml ('<fetch version="1.0" mapping="logical" returntotalrecordcount="true">' +
        '<entity name="environmentvariabledefinition">' +
        '<attribute name="displayname" /><attribute name="schemaname" />' +
        '<attribute name="defaultvalue" /><attribute name="description" />' +
        '<attribute name="environmentvariabledefinitionid" />' +
        '<order attribute="displayname" descending="false" />' +
        '<filter type="and"><condition attribute="schemaname" operator="like" value="pwrp\_%" /></filter>' +
        '</entity></fetch>') `
    -LayoutXml ('<grid name="resultset" object="OBJECTTYPECODE" jump="displayname" select="1" icon="1" preview="1">' +
        '<row name="result" id="environmentvariabledefinitionid">' +
        '<cell name="displayname" width="220" />' +
        '<cell name="defaultvalue" width="140" />' +
        '<cell name="description" width="520" />' +
        '<cell name="schemaname" width="220" />' +
        '</row></grid>')

Set-FilteredView -Entity "environmentvariablevalue" -Name "IVR toolkit setting values" `
    -Description "Values set for Contact Center IVR Toolkit environment variables." `
    -FetchXml ('<fetch version="1.0" mapping="logical" returntotalrecordcount="true">' +
        '<entity name="environmentvariablevalue">' +
        '<attribute name="value" /><attribute name="environmentvariablevalueid" />' +
        '<attribute name="environmentvariabledefinitionid" />' +
        '<order attribute="environmentvariabledefinitionid" descending="false" />' +
        '<link-entity name="environmentvariabledefinition" from="environmentvariabledefinitionid" ' +
        'to="environmentvariabledefinitionid" alias="def" link-type="inner">' +
        '<attribute name="displayname" />' +
        '<filter type="and"><condition attribute="schemaname" operator="like" value="pwrp\_%" /></filter>' +
        '</link-entity></entity></fetch>') `
    -LayoutXml ('<grid name="resultset" object="OBJECTTYPECODE" jump="environmentvariabledefinitionid" select="1" icon="1" preview="1">' +
        '<row name="result" id="environmentvariablevalueid">' +
        '<cell name="def.displayname" width="260" disableSorting="1" />' +
        '<cell name="value" width="320" />' +
        '</row></grid>')

# --- Sitemap ------------------------------------------------------------------
# Shape copied from a working app in the same organisation. The Client and Sku attributes
# are not decoration: a SubArea without them is dropped by the Unified Interface.
function New-SubArea {
    param($Area)
    $suffix = $Area.Entity -replace '^pwrp_', ''
    return "<SubArea Id=`"pwrp_sub_$suffix`" VectorIcon=`"/_imgs/TableIconsFluentV9/$($Area.Icon).svg`" " +
        "Icon=`"/_imgs/imagestrips/transparent_spacer.gif`" " +
        "Entity=`"$($Area.Entity)`" Client=`"All,Outlook,OutlookLaptopClient,OutlookWorkstationClient,Web`" " +
        "AvailableOffline=`"true`" PassParams=`"false`" Sku=`"All,OnPremise,Live,SPLA`">" +
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
Invoke-Dataverse -Method POST -Path "/api/data/v9.2/PublishXml" -Body @{
    ParameterXml = "<importexportxml><appmodules><appmodule>$AppId</appmodule></appmodules>" +
                   "<sitemaps><sitemap>$sitemapId</sitemap></sitemaps>" +
                   # The settings views are saved queries, and a saved query only goes live
                   # when its table is published.
                   "<entities><entity>environmentvariabledefinition</entity>" +
                   "<entity>environmentvariablevalue</entity></entities></importexportxml>"
} | Out-Null

Write-Host "`nApp ready. Open it from the Power Apps maker portal, or Dynamics 365 home." -ForegroundColor Green
Write-Host "Re-export the solution to commit it: ./build/Export-Solution.ps1" -ForegroundColor Gray
