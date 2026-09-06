<#
.SYNOPSIS
    Builds the Contact Center IVR Toolkit plugin assembly and packs the solution.

.DESCRIPTION
    Run this before deploy.ps1. It restores, builds in Release, runs the unit tests,
    and packs the solution folder into managed and unmanaged zips under ./out.

.NOTES
    The version comes from VERSION at the repository root and the build number is raised
    on every run, so two builds never share an assembly version. That matters more than it
    sounds: moving the build number is what forces the Dataverse sandbox to drop its cached
    copy of the assembly, and a build that reuses one can deploy and change nothing.

    Dataverse treats a plugin assembly's major and minor version as part of its identity.
    Changing either is a different assembly, and updating the registered one is refused
    with "Plugin Assembly fully qualified name has changed". So the assembly stays on 1.0
    for ever and carries the build number in its third part, while the solution carries the
    real version. build/Version.ps1 has the whole of it.

.EXAMPLE
    ./build.ps1

.EXAMPLE
    # Rebuild the version that is already there, for a packaging change or a retry.
    ./build.ps1 -NoVersionBump

.EXAMPLE
    # Pin one, for reproducing a past build.
    ./build.ps1 -Version 3.4.0.7
#>
[CmdletBinding()]
param(
    # Overrides VERSION entirely. MAJOR.MINOR.PATCH.BUILD.
    [string]$Version,
    # Builds what VERSION already says instead of raising the build number.
    [switch]$NoVersionBump,
    [switch]$SkipTests,
    [string]$OutputPath = "$PSScriptRoot/../out"
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot/.."

. "$PSScriptRoot/Version.ps1"

if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "-Version must be MAJOR.MINOR.PATCH.BUILD, for example 3.4.0.7."
    }
    Set-Content -Path (Join-Path $root "VERSION") -Value $Version -NoNewline
    $v = Get-ToolkitVersion -Root $root
}
elseif ($NoVersionBump) {
    $v = Get-ToolkitVersion -Root $root
}
else {
    $v = Step-ToolkitVersion -Root $root
}

Write-ToolkitVersion -Version $v -Root $root

Write-Host "Contact Center IVR Toolkit $($v.Release) build $($v.Build)" -ForegroundColor Cyan
Write-Host "  solution $($v.Solution), assembly $($v.Assembly)" -ForegroundColor DarkGray

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
    /p:Version=$($v.Assembly)
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

# 4. Web resources into the solution folder
# The Settings page exists twice: src/webresources/pwrp_settings.html, which is edited,
# and solution/WebResources/pwrp_settings, which is packed. The second is written by
# Export-Solution.ps1 and by nothing else, so every edit to the first was packed only if
# somebody happened to export afterwards. They diverged for two releases, and the built
# solution shipped a page older than the repository, managed zips included.
#
# Copying before the pack makes src the source of truth and the packed copy a build
# artefact. It stays checked in, because pac solution pack needs the whole folder and the
# .data.xml sidecar beside it carries the id and type that are not in the HTML.
Write-Host "Syncing web resources into the solution" -ForegroundColor Cyan

$webResources = @(
    @{ From = "$root/src/webresources/pwrp_settings.html"; To = "$root/solution/WebResources/pwrp_settings" }
    @{ From = "$root/build/assets/app-icon.svg";           To = "$root/solution/WebResources/pwrp_/icons/ivrtoolkit.svg" }
)

foreach ($resource in $webResources) {
    if (-not (Test-Path $resource.From)) { throw "Web resource source not found at $($resource.From)." }
    if (-not (Test-Path $resource.To)) { throw "No packed copy at $($resource.To). Export the solution first, so the .data.xml sidecar exists." }

    # Compared as bytes rather than copied blindly, so the build says when the two had
    # drifted. Silence here means an export has kept up; a line means it had not, which is
    # the state that shipped a stale page.
    $from = [IO.File]::ReadAllBytes($resource.From)
    $to = [IO.File]::ReadAllBytes($resource.To)

    if ([Convert]::ToBase64String($from) -eq [Convert]::ToBase64String($to)) {
        Write-Host "  = $(Split-Path $resource.To -Leaf)" -ForegroundColor DarkGray
    }
    else {
        [IO.File]::WriteAllBytes($resource.To, $from)
        Write-Host "  ~ $(Split-Path $resource.To -Leaf), was out of date" -ForegroundColor Yellow
    }
}

# 5. Pack solution
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

foreach ($type in @("Managed", "Unmanaged")) {
    Write-Host "Packing $type solution" -ForegroundColor Cyan
    & pac solution pack `
        --zipfile "$OutputPath/PowerPeteIvrToolkitCore_$($v.Solution)_$type.zip" `
        --folder "$root/solution" `
        --packagetype $type
    if ($LASTEXITCODE -ne 0) { throw "Solution pack failed for $type." }
}

Write-Host "Build complete. Artefacts in $OutputPath" -ForegroundColor Green
