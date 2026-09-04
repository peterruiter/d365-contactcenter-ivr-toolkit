<#
.SYNOPSIS
    Exports the solution from a development environment and unpacks it into ./solution.

.DESCRIPTION
    Run after any schema, form, app or flow change in the development environment. The
    unpacked folder is what the pipeline packs, so an unexported change is a change that
    never ships.

    Commit the result. Review the diff before you do, because the exporter picks up
    unrelated changes from anyone else working in the same environment.

.EXAMPLE
    ./Export-Solution.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$SolutionName = "PowerPeteIvrToolkitCore",
    [string]$SolutionFolder = "$PSScriptRoot/../solution"
)

$ErrorActionPreference = "Stop"
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "$SolutionName.zip"

& pac auth create --environment $EnvironmentUrl --name pwrp-export 2>$null
& pac auth select --name pwrp-export

Write-Host "Publishing customisations" -ForegroundColor Cyan
& pac solution publish
if ($LASTEXITCODE -ne 0) { throw "Publish failed." }

Write-Host "Exporting $SolutionName" -ForegroundColor Cyan
& pac solution export --path $temp --name $SolutionName --managed false --overwrite
if ($LASTEXITCODE -ne 0) { throw "Export failed." }

Write-Host "Unpacking into $SolutionFolder" -ForegroundColor Cyan
& pac solution unpack --zipfile $temp --folder $SolutionFolder --packagetype Unmanaged --allowDelete
if ($LASTEXITCODE -ne 0) { throw "Unpack failed." }

Remove-Item $temp -Force

Write-Host @"

Exported. Before committing:
  1. git diff --stat, and check nothing unrelated came along
  2. Confirm the plugin assembly version moved if the code changed
  3. Confirm environment variable DEFAULT values are generic, not client values
     Client values belong in environment variable values, not defaults

"@ -ForegroundColor Yellow
