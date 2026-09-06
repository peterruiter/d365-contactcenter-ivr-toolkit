<#
.SYNOPSIS
    One version number, and the rules for turning it into the three the platform wants.

.DESCRIPTION
    The repository had three version schemes that disagreed: the changelog at 3.4.0, the
    solution at 1.0.0.0 and the plugin assembly at 1.0.8.0. Nothing said which one named a
    release, and a reader picking the wrong one is not a hypothetical.

    VERSION at the repository root is now the only place a version is written by hand. It
    holds four parts, MAJOR.MINOR.PATCH.BUILD:

      MAJOR.MINOR.PATCH   the release, and the contract. Bumped deliberately, by the table
                          at the top of CHANGELOG.md. This is the number a person means.
      BUILD               bumped automatically by build.ps1. Not a release, so it never
                          appears in CHANGELOG.md.

    The plugin assembly cannot follow it. Dataverse treats an assembly's major and minor
    version as part of its identity, so moving either is a different assembly and updating
    the registered one is refused with "Plugin Assembly fully qualified name has changed",
    which means rebinding every Custom API. The assembly therefore stays on 1.0 for ever
    and carries the build number in its third part:

      VERSION 3.4.0.9  ->  solution 3.4.0.9,  assembly 1.0.9.0

    So the build number is what ties an assembly to the release it was cut for. Given an
    assembly at 1.0.9.0 you can say it belongs to the ninth build, and the solution version
    tells you that build was 3.4.0. That is the most unification the platform allows, and
    pretending otherwise would cost a re-registration every release.
#>

function Get-ToolkitVersion {
    param([string]$Root = "$PSScriptRoot/..")

    $path = Join-Path $Root "VERSION"
    if (-not (Test-Path $path)) { throw "VERSION not found at $path." }

    $raw = (Get-Content $path -Raw).Trim()
    if ($raw -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "VERSION must be MAJOR.MINOR.PATCH.BUILD, found '$raw'."
    }

    $parts = $raw.Split('.')
    [pscustomobject]@{
        Full     = $raw
        Release  = "$($parts[0]).$($parts[1]).$($parts[2])"   # what CHANGELOG.md calls it
        Build    = [int]$parts[3]
        Solution = $raw
        Assembly = "1.0.$($parts[3]).0"                        # major.minor pinned, see above
    }
}

function Step-ToolkitVersion {
    param([string]$Root = "$PSScriptRoot/..")

    $current = Get-ToolkitVersion -Root $Root
    $next = "$($current.Release).$($current.Build + 1)"
    Set-Content -Path (Join-Path $Root "VERSION") -Value $next -NoNewline
    return Get-ToolkitVersion -Root $Root
}

function Write-ToolkitVersion {
    <#
        Stamps the version into the two files that carry their own copy. Both are read by
        tooling that cannot ask VERSION for it: MSBuild needs it in the csproj, and
        "pac solution pack" reads Solution.xml.
    #>
    param(
        [Parameter(Mandatory = $true)]$Version,
        [string]$Root = "$PSScriptRoot/.."
    )

    $csproj = Join-Path $Root "src/PowerPete.IvrToolkit.Plugins/PowerPete.IvrToolkit.Plugins.csproj"
    $xml = Get-Content $csproj -Raw
    $updated = $xml -replace '<Version>[^<]*</Version>', "<Version>$($Version.Assembly)</Version>"
    if ($updated -ne $xml) { Set-Content -Path $csproj -Value $updated -NoNewline }

    $solutionXml = Join-Path $Root "solution/Other/Solution.xml"
    if (Test-Path $solutionXml) {
        $xml = Get-Content $solutionXml -Raw
        $updated = $xml -replace '<Version>[^<]*</Version>', "<Version>$($Version.Solution)</Version>"
        if ($updated -ne $xml) { Set-Content -Path $solutionXml -Value $updated -NoNewline }
    }
}
