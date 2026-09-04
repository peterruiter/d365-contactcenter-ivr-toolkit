<#
.SYNOPSIS
    Builds the Contact Center IVR Toolkit plugin assembly and packs the solution.

.DESCRIPTION
    Run this before deploy.ps1. It restores, builds in Release, runs the unit tests,
    and packs the solution folder into managed and unmanaged zips under ./out.

.EXAMPLE
    ./build.ps1 -Version 1.0.3
#>
[CmdletBinding()]
param(
    [string]$Version = "1.0.0",
    [switch]$SkipTests,
    [string]$OutputPath = "$PSScriptRoot/../out"
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot/.."

Write-Host "Contact Center IVR Toolkit build $Version" -ForegroundColor Cyan

# 1. Signing key. Plugin assemblies must be strong named.
$keyPath = "$PSScriptRoot/PowerPete.IvrToolkit.snk"
if (-not (Test-Path $keyPath)) {
    Write-Host "Generating signing key" -ForegroundColor Yellow
    & sn -k $keyPath
    if ($LASTEXITCODE -ne 0) {
        throw "Could not generate a signing key. Install the .NET Framework SDK, or supply your own snk."
    }
}

# 2. Build
Write-Host "Building plugin assembly" -ForegroundColor Cyan
dotnet build "$root/src/PowerPete.IvrToolkit.Plugins/PowerPete.IvrToolkit.Plugins.csproj" `
    --configuration Release `
    /p:Version=$Version
if ($LASTEXITCODE -ne 0) { throw "Build failed." }

# 3. Tests
if (-not $SkipTests) {
    Write-Host "Running unit tests" -ForegroundColor Cyan
    dotnet test "$root/tests/PowerPete.IvrToolkit.Tests/PowerPete.IvrToolkit.Tests.csproj" --configuration Release
    if ($LASTEXITCODE -ne 0) { throw "Tests failed. Fix them before deploying to a client environment." }
}

# 4. Pack solution
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

foreach ($type in @("Managed", "Unmanaged")) {
    Write-Host "Packing $type solution" -ForegroundColor Cyan
    & pac solution pack `
        --zipfile "$OutputPath/PowerPeteIvrToolkitCore_$($Version)_$type.zip" `
        --folder "$root/solution" `
        --packagetype $type
    if ($LASTEXITCODE -ne 0) { throw "Solution pack failed for $type." }
}

Write-Host "Build complete. Artefacts in $OutputPath" -ForegroundColor Green
