<#
.SYNOPSIS
    Puts the toolkit's columns onto the main forms and default views.

.DESCRIPTION
    Dataverse builds a table's default form when the table is created, so it contains the
    primary column and the owner and nothing else. Every column added afterwards, which is
    all of them, is missing. The same goes for the default view. The result is an app where
    every record looks empty.

    This rewrites the main form for each toolkit table from schema.json, and widens the
    default public view to match. Run it after New-Schema.ps1, and again after adding a
    column.

    Safe to run repeatedly. The form is rebuilt from schema.json every time, so schema.json
    stays the single description of what a record holds.

.EXAMPLE
    ./Update-Forms.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$SchemaFile = "$PSScriptRoot/schema.json",
    [string]$SolutionName = "PowerPeteIvrToolkitCore",
    [int]$ViewColumns = 5
)

$ErrorActionPreference = "Stop"
$schema = Get-Content $SchemaFile -Raw | ConvertFrom-Json

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

# Harvested from forms that work in a real organisation rather than from memory. Two of
# these have alternatives: a Boolean can also be a checkbox, and an Integer can be the
# duration control that task.durationminutes uses. These are the ordinary ones.
$classIds = @{
    String           = "{4273EDBD-AC1D-40d3-9FB2-095C621B552D}"
    Memo             = "{E0DECE4B-6FC8-4a8f-A065-082708572369}"
    Integer          = "{C6D124CA-7EDA-4a60-AEA9-7FB8D318B68F}"
    Boolean          = "{3EF39988-22BB-4f0b-BBBE-64B5A3748AEE}"
    Picklist         = "{3EF39988-22BB-4f0b-BBBE-64B5A3748AEE}"
    DateTime         = "{5B773807-9FB2-42db-97C3-7A91EFF8ADFF}"
    Lookup           = "{270BD3DB-D9AF-4782-9025-509E298DEC0A}"
    Owner            = "{270BD3DB-D9AF-4782-9025-509E298DEC0A}"
    Uniqueidentifier = "{4273EDBD-AC1D-40d3-9FB2-095C621B552D}"
}

# Stable ids, so re-running produces the same form rather than a new one every time.
function Get-StableGuid {
    param([string]$Seed)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { return [Guid]::new($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Seed))).ToString() }
    finally { $md5.Dispose() }
}

function ConvertTo-XmlText {
    param([string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

$updated = 0
$problems = @()

foreach ($table in $schema.tables) {
    $logical = $table.logicalName
    Write-Host "`n$logical" -ForegroundColor Cyan

    # --- What the table actually holds ---------------------------------------
    $attributes = @{}
    foreach ($a in (Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/EntityDefinitions(LogicalName='$logical')/Attributes?`$select=LogicalName,AttributeType,DisplayName").value) {
        $attributes[$a.LogicalName] = $a
    }

    # Primary name first, then the columns in the order schema.json declares them, then
    # the owner. A lookup column is stored under its own logical name.
    $fields = @()
    $fields += $table.primaryField.name.ToLowerInvariant()
    foreach ($column in $table.columns) { $fields += $column.name.ToLowerInvariant() }
    $fields += "ownerid"

    $rows = ""
    foreach ($field in $fields) {
        if (-not $attributes.ContainsKey($field)) {
            $problems += "$logical.$field is on schema.json but not on the table"
            continue
        }

        $type = $attributes[$field].AttributeType
        if (-not $classIds.ContainsKey($type)) {
            $problems += "$logical.$field is a $type, which has no known control"
            continue
        }

        $label = if ($attributes[$field].DisplayName.UserLocalizedLabel) {
            $attributes[$field].DisplayName.UserLocalizedLabel.Label
        } else { $field }

        $cellId = Get-StableGuid -Seed "$logical.$field.cell"
        $rows += "<row><cell id=`"{$cellId}`"><labels><label description=`"$(ConvertTo-XmlText $label)`" languagecode=`"1033`" /></labels>" +
                 "<control id=`"$field`" classid=`"$($classIds[$type])`" datafieldname=`"$field`" /></cell></row>"
    }

    # --- Main form ------------------------------------------------------------
    $forms = (Invoke-Dataverse -Method GET `
        -Path "/api/data/v9.2/systemforms?`$select=formid,name,type&`$filter=objecttypecode eq '$logical' and type eq 2").value
    if ($forms.Count -eq 0) {
        $problems += "$logical has no main form"
        continue
    }

    $tabId = Get-StableGuid -Seed "$logical.tab"
    $sectionId = Get-StableGuid -Seed "$logical.section"
    $formXml = "<form><tabs><tab verticallayout=`"true`" id=`"{$tabId}`" IsUserDefined=`"1`">" +
        "<labels><label description=`"General`" languagecode=`"1033`" /></labels>" +
        "<columns><column width=`"100%`"><sections>" +
        "<section showlabel=`"false`" showbar=`"false`" IsUserDefined=`"0`" id=`"{$sectionId}`">" +
        "<labels><label description=`"General`" languagecode=`"1033`" /></labels>" +
        "<rows>$rows</rows>" +
        "</section></sections></column></columns></tab></tabs></form>"

    Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/systemforms($($forms[0].formid))" `
        -SolutionName $SolutionName -Body @{ formxml = $formXml } | Out-Null
    Write-Host "  form: $(($rows | Select-String '<row>' -AllMatches).Matches.Count) fields" -ForegroundColor DarkGray

    # --- Default public view --------------------------------------------------
    # Only the displayed columns are rebuilt. The existing filter is left alone, because it
    # is what makes the active view active.
    $views = (Invoke-Dataverse -Method GET -Path ("/api/data/v9.2/savedqueries" +
        "?`$select=savedqueryid,name,layoutxml,fetchxml,isdefault&`$filter=returnedtypecode eq '$logical' and querytype eq 0")).value
    $view = $views | Where-Object { $_.isdefault } | Select-Object -First 1
    if (-not $view) { $view = $views | Select-Object -First 1 }
    if (-not $view) {
        $problems += "$logical has no public view"
        continue
    }

    $shown = @($fields | Where-Object { $_ -ne "ownerid" -and $attributes.ContainsKey($_) } | Select-Object -First $ViewColumns)

    try {
        $fetch = [xml]$view.fetchxml
        $entityNode = $fetch.SelectSingleNode("//entity")
        foreach ($field in $shown) {
            if (-not $entityNode.SelectSingleNode("attribute[@name='$field']")) {
                $node = $fetch.CreateElement("attribute")
                $node.SetAttribute("name", $field)
                [void]$entityNode.PrependChild($node)
            }
        }

        $layout = [xml]$view.layoutxml
        $rowNode = $layout.SelectSingleNode("//row")
        foreach ($cell in @($rowNode.SelectNodes("cell"))) { [void]$rowNode.RemoveChild($cell) }
        foreach ($field in $shown) {
            $cell = $layout.CreateElement("cell")
            $cell.SetAttribute("name", $field)
            $cell.SetAttribute("width", $(if ($field -eq $shown[0]) { "200" } else { "150" }))
            [void]$rowNode.AppendChild($cell)
        }

        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/savedqueries($($view.savedqueryid))" `
            -SolutionName $SolutionName -Body @{
                fetchxml  = $fetch.OuterXml
                layoutxml = $layout.OuterXml
            } | Out-Null
        Write-Host "  view '$($view.name)': $($shown -join ', ')" -ForegroundColor DarkGray
    }
    catch {
        $problems += "$logical view: $($_.Exception.Message)"
    }

    $updated++
}

# --- Publish ------------------------------------------------------------------
# Forms and views are invisible until published.
Write-Host "`nPublishing" -ForegroundColor Cyan
$entityXml = ($schema.tables | ForEach-Object { "<entity>$($_.logicalName)</entity>" }) -join ""
Invoke-Dataverse -Method POST -Path "/api/data/v9.2/PublishXml" -Body @{
    ParameterXml = "<importexportxml><entities>$entityXml</entities></importexportxml>"
} | Out-Null

Write-Host "`n$updated tables updated." -ForegroundColor Green
if ($problems.Count -gt 0) {
    Write-Host "$($problems.Count) problem(s):" -ForegroundColor Yellow
    $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
