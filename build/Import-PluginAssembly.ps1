<#
.SYNOPSIS
    Registers the merged plugin assembly and its plugin types in a development environment.

.DESCRIPTION
    Breaks the bootstrap deadlock. Register-CustomApis.ps1 needs plugin types to bind each
    Custom API to, plugin types need a registered assembly, and the assembly normally
    arrives inside a solution zip that cannot be packed until the solution folder has been
    exported, which cannot happen until the components exist. Registering the assembly
    directly skips the loop.

    Use this in a development environment only. Anywhere else the assembly arrives in the
    managed solution, which is the supported path.

    Safe to run repeatedly. An existing assembly has its content updated in place, which
    keeps the plugin type ids and therefore the Custom API bindings stable.

.EXAMPLE
    ./Import-PluginAssembly.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$AssemblyPath = "$PSScriptRoot/../src/PowerPete.IvrToolkit.Plugins/bin/Release/net462/merged/PowerPete.IvrToolkit.Plugins.dll",
    [string]$DefinitionFile = "$PSScriptRoot/customapis.json",
    [string]$SolutionName = "PowerPeteIvrToolkitCore"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $AssemblyPath)) {
    throw "Assembly not found at $AssemblyPath. Run build.ps1 first."
}

$definition = Get-Content $DefinitionFile -Raw | ConvertFrom-Json

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

# --- Assembly identity --------------------------------------------------------
$full = (Resolve-Path $AssemblyPath).Path
$name = [System.Reflection.AssemblyName]::GetAssemblyName($full)
$token = ($name.GetPublicKeyToken() | ForEach-Object { $_.ToString("x2") }) -join ""

if (-not $token) {
    throw "The assembly is not strong named. Dataverse will not accept it."
}

Write-Host "$($name.Name) $($name.Version) publickeytoken=$token" -ForegroundColor Cyan
Write-Host "  $([math]::Round((Get-Item $full).Length / 1KB)) KB" -ForegroundColor DarkGray

$content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($full))

# --- Assembly -----------------------------------------------------------------
$existing = (Invoke-Dataverse -Method GET `
    -Path "/api/data/v9.2/pluginassemblies?`$select=pluginassemblyid,version&`$filter=name eq '$($name.Name)'").value

if ($existing.Count -gt 0) {
    $assemblyId = $existing[0].pluginassemblyid

    # Version goes up with the content. The sandbox caches a loaded assembly by version, so
    # patching content alone leaves it running the previous build even though the row is
    # correct. Build and revision may change on an update; major and minor may not, those
    # need a new registration.
    Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/pluginassemblies($assemblyId)" -SolutionName $SolutionName -Body @{
        content = $content
        version = $name.Version.ToString()
    } | Out-Null

    Write-Host "  = assembly updated in place at $($name.Version)" -ForegroundColor DarkGray
    if ($existing[0].version -eq $name.Version.ToString()) {
        Write-Host "    version unchanged, so the sandbox may keep serving the cached build." -ForegroundColor Yellow
        Write-Host "    Rebuild with -Version to force a reload: ./build/build.ps1 -Version 1.0.1" -ForegroundColor Yellow
    }
}
else {
    $created = Invoke-Dataverse -Method POST -Path "/api/data/v9.2/pluginassemblies" -SolutionName $SolutionName -Representation -Body @{
        name            = $name.Name
        content         = $content
        culture         = ""
        version         = $name.Version.ToString()
        publickeytoken  = $token
        sourcetype      = 0   # Database. The sandbox loads it from here.
        isolationmode   = 2   # Sandbox. Online will not accept anything else.
    }
    $assemblyId = $created.pluginassemblyid
    Write-Host "  + assembly registered" -ForegroundColor DarkGray
}

# --- Plugin types -------------------------------------------------------------
# One per Custom API. Register-CustomApis.ps1 resolves these by typename, so the names
# here and the "type" values in customapis.json have to stay in step.
Write-Host "`nPlugin types" -ForegroundColor Cyan

$registered = @{}
$current = (Invoke-Dataverse -Method GET `
    -Path "/api/data/v9.2/plugintypes?`$select=plugintypeid,typename&`$filter=_pluginassemblyid_value eq $assemblyId").value
foreach ($type in $current) { $registered[$type.typename] = $type.plugintypeid }

$added = 0
foreach ($api in $definition.apis) {
    if ($registered.ContainsKey($api.type)) {
        Write-Host "  = $($api.type)" -ForegroundColor DarkGray
        continue
    }

    Invoke-Dataverse -Method POST -Path "/api/data/v9.2/plugintypes" -SolutionName $SolutionName -Body @{
        typename                    = $api.type
        friendlyname                = $api.type
        name                        = $api.type
        "pluginassemblyid@odata.bind" = "/pluginassemblies($assemblyId)"
    } | Out-Null
    Write-Host "  + $($api.type)" -ForegroundColor DarkGray
    $added++
}

Write-Host "`n$($definition.apis.Count) plugin types present, $added newly registered" -ForegroundColor Green
Write-Host "Next: ./build/Register-CustomApis.ps1 -EnvironmentUrl $EnvironmentUrl" -ForegroundColor Gray
