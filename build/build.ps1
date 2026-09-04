<#
.SYNOPSIS
    Builds the Contact Center IVR Toolkit plugin assembly and packs the solution.

.DESCRIPTION
    Run this before deploy.ps1. It restores, builds in Release, runs the unit tests,
    and packs the solution folder into managed and unmanaged zips under ./out.

.NOTES
    Keep -Version on the 1.0.x line for anything that will be updated in place.

    Dataverse treats a plugin assembly's major and minor version as part of its identity.
    Changing either is a different assembly, and updating the registered one is refused
    with "Plugin Assembly fully qualified name has changed". Build and revision may move
    freely, and moving them is what forces the sandbox to drop its cached copy.

    So the assembly version is not the product version. The contract can be at 1.1.0 while
    the assembly is at 1.0.6. Raise major or minor only when you intend to delete and
    re-register, which means rebinding every Custom API.

.EXAMPLE
    ./build.ps1 -Version 1.0.6
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
# Generated directly via RSACryptoServiceProvider rather than shelling out to sn.exe:
# a .snk is just an RSA private key CSP blob, and sn.exe is part of the .NET Framework
# SDK tooling, which is not reliably on PATH even when Visual Studio is installed.
$keyPath = "$PSScriptRoot/PowerPete.IvrToolkit.snk"
if (-not (Test-Path $keyPath)) {
    Write-Host "Generating signing key" -ForegroundColor Yellow
    $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new(2048)
    try {
        [System.IO.File]::WriteAllBytes($keyPath, $rsa.ExportCspBlob($true))
    } finally {
        $rsa.Dispose()
    }
}

# 2. Build
# Built with full-framework MSBuild, not "dotnet build". ILRepack's strong-name signing
# step calls System.Reflection.StrongNameKeyPair, which throws PlatformNotSupportedException
# under the cross-platform dotnet SDK host regardless of OS. Only the desktop CLR that
# ships with Visual Studio / Build Tools implements it.
Write-Host "Building plugin assembly" -ForegroundColor Cyan
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = $null
if (Test-Path $vswhere) {
    $msbuild = & $vswhere -latest -prerelease -requires Microsoft.Component.MSBuild `
        -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
}
if (-not $msbuild) {
    $cmd = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) { $msbuild = $cmd.Source }
}
if (-not $msbuild) {
    throw "MSBuild.exe not found. The plugin targets net462 and its merge step needs " +
        "full-framework MSBuild, which 'dotnet build' cannot provide. Install Visual " +
        "Studio or the Build Tools for Visual Studio."
}

& $msbuild "$root/src/PowerPete.IvrToolkit.Plugins/PowerPete.IvrToolkit.Plugins.csproj" `
    /restore `
    /p:Configuration=Release `
    /p:Version=$Version
if ($LASTEXITCODE -ne 0) { throw "Build failed." }

# 3. Tests
if (-not $SkipTests) {
    # Debug, not Release: the plugin's MergeDependencies target runs AfterTargets="Build"
    # whenever Configuration=='Release', including when pulled in as a ProjectReference.
    # "dotnet test" builds through the cross-platform host, which cannot run that target
    # (see the MSBuild.exe note above), and tests do not need the signed merged output.
    Write-Host "Running unit tests" -ForegroundColor Cyan
    dotnet test "$root/tests/PowerPete.IvrToolkit.Tests/PowerPete.IvrToolkit.Tests.csproj" --configuration Debug
    if ($LASTEXITCODE -ne 0) { throw "Tests failed. Fix them before deploying." }
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
