<#
.SYNOPSIS
    Creates the application user a Copilot Studio agent or the MCP server authenticates as.

.DESCRIPTION
    Both integration routes connect as an application user rather than as a person, and
    that user needs the Power Pete IVR Reader role. The role has existed since the schema
    was built and nothing has ever authenticated with it, so this is also the first real
    test of whether it is sufficient.

    Two ways in. With no -AppId, an Entra application and its Dataverse application user
    are created together, and the client secret is printed once and never stored. With
    -AppId, an application you already registered is given the role instead.

    Do not substitute System Administrator. The role is minimal on purpose, and running
    the agent as an administrator hides every privilege the toolkit is missing until a
    client environment finds it.

.EXAMPLE
    ./New-ApplicationUser.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com

.EXAMPLE
    ./New-ApplicationUser.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com -AppId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$AppId,
    [string]$AppName = "Power Pete IVR Toolkit",
    [string]$RoleName = "Power Pete IVR Reader"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

# The role has to exist before anything is pointed at it, and a typo here would otherwise
# surface as a permission problem days later.
$role = (Invoke-Dataverse -Method GET `
    -Path "/api/data/v9.2/roles?`$select=roleid,name&`$filter=name eq '$($RoleName -replace "'", "''")'").value
if ($role.Count -eq 0) {
    throw "Security role '$RoleName' does not exist. Run New-SecurityRole.ps1 first."
}
Write-Host "Role '$RoleName' found" -ForegroundColor DarkGray

Connect-Pac -EnvironmentUrl $EnvironmentUrl -ProfileName "pwrp-appuser"

if (-not $AppId) {
    Write-Host "`nCreating an Entra application and its application user" -ForegroundColor Cyan
    Write-Host "This registers an application in your tenant." -ForegroundColor Yellow

    $output = & pac admin create-service-principal --environment $EnvironmentUrl --name $AppName --role $RoleName 2>&1
    $output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { throw "pac admin create-service-principal failed." }

    $text = $output | Out-String
    $AppId = ([regex]::Match($text, '(?im)^\s*Application Id\s*:?\s*([0-9a-fA-F-]{36})')).Groups[1].Value
    if (-not $AppId) {
        $AppId = ([regex]::Match($text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')).Value
    }

    Write-Host "`nThe client secret is in the output above and is shown once." -ForegroundColor Yellow
    Write-Host "Put it wherever you keep secrets. Not in this repository." -ForegroundColor Yellow
}
else {
    Write-Host "`nGiving application $AppId the '$RoleName' role" -ForegroundColor Cyan
    & pac admin assign-user --environment $EnvironmentUrl --user $AppId --application-user --role $RoleName
    if ($LASTEXITCODE -ne 0) { throw "pac admin assign-user failed." }
}

# --- Verify -------------------------------------------------------------------
# pac reporting success is not the same as the user existing with the role attached.
Write-Host "`nVerifying" -ForegroundColor Cyan

$appUser = (Invoke-Dataverse -Method GET -Path ("/api/data/v9.2/systemusers" +
    "?`$select=systemuserid,fullname,applicationid,isdisabled&`$filter=applicationid eq $AppId")).value

if ($appUser.Count -eq 0) {
    throw "No application user for $AppId. The Entra application may exist without one."
}

$user = $appUser[0]
Write-Host "  user '$($user.fullname)' id=$($user.systemuserid) disabled=$($user.isdisabled)" -ForegroundColor DarkGray

$assigned = (Invoke-Dataverse -Method GET `
    -Path "/api/data/v9.2/systemusers($($user.systemuserid))/systemuserroles_association?`$select=name").value
$names = @($assigned | ForEach-Object { $_.name })
Write-Host "  roles: $($names -join ', ')" -ForegroundColor DarkGray

if ($names -notcontains $RoleName) {
    throw "The application user exists but does not hold '$RoleName'."
}
if ($names -contains "System Administrator") {
    Write-Host "  WARNING: it also holds System Administrator, which hides any missing privilege." -ForegroundColor Yellow
}

Write-Host "`nApplication user ready." -ForegroundColor Green
Write-Host "  Application (client) id: $AppId" -ForegroundColor Gray
Write-Host @"

Prove the role is sufficient before an agent depends on it:

  ./build/Test-Endpoints.ps1 -EnvironmentUrl $EnvironmentUrl ``
      -TenantId <tenant> -ClientId $AppId -ClientSecret <secret>

Anything that fails there is a privilege the role is missing, not a toolkit fault.
"@ -ForegroundColor Gray
