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
$tempManaged = Join-Path ([System.IO.Path]::GetTempPath()) "${SolutionName}_managed.zip"

. "$PSScriptRoot/Common.ps1"
Connect-Pac -EnvironmentUrl $EnvironmentUrl -ProfileName "pwrp-export"

Write-Host "Publishing customisations" -ForegroundColor Cyan
& pac solution publish
if ($LASTEXITCODE -ne 0) { throw "Publish failed." }

# Both flavours, because the unpacked folder records which one it came from and the
# pipeline packs a managed zip to ship. Unpacking unmanaged alone leaves a folder that
# "pac solution pack --packagetype Managed" refuses with a package type mismatch.
Write-Host "Exporting $SolutionName unmanaged" -ForegroundColor Cyan
& pac solution export --path $temp --name $SolutionName --managed false --overwrite
if ($LASTEXITCODE -ne 0) { throw "Export failed." }

Write-Host "Exporting $SolutionName managed" -ForegroundColor Cyan
& pac solution export --path $tempManaged --name $SolutionName --managed true --overwrite
if ($LASTEXITCODE -ne 0) { throw "Managed export failed." }

# --allowDelete removes anything in the folder that is not in the export, and README.md
# and the promotion flow are written by hand rather than exported. They are moved aside
# and put back, and only where the export did not produce a file of the same name.
$preserve = @("README.md", "Workflows")
$backup = Join-Path ([System.IO.Path]::GetTempPath()) "pwrp-solution-preserve"
if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
New-Item -ItemType Directory -Force -Path $backup | Out-Null

foreach ($item in $preserve) {
    $source = Join-Path $SolutionFolder $item
    if (Test-Path $source) {
        Copy-Item $source -Destination $backup -Recurse -Force
        Write-Host "Holding on to $item" -ForegroundColor DarkGray
    }
}

Write-Host "Unpacking into $SolutionFolder" -ForegroundColor Cyan
& pac solution unpack --zipfile $temp --folder $SolutionFolder --packagetype Both --allowDelete
if ($LASTEXITCODE -ne 0) { throw "Unpack failed." }

foreach ($item in $preserve) {
    $restored = Join-Path $backup $item
    $target = Join-Path $SolutionFolder $item
    if ((Test-Path $restored) -and -not (Test-Path $target)) {
        Copy-Item $restored -Destination $SolutionFolder -Recurse -Force
        Write-Host "Put $item back" -ForegroundColor DarkGray
    }
}

Remove-Item $backup -Recurse -Force
Remove-Item $temp -Force
Remove-Item $tempManaged -Force

Write-Host @"

Exported. Before committing:
  1. git diff --stat, and check nothing unrelated came along
  2. Confirm the plugin assembly version moved if the code changed
  3. Confirm environment variable DEFAULT values are generic, not client values
     Client values belong in environment variable values, not defaults

"@ -ForegroundColor Yellow
