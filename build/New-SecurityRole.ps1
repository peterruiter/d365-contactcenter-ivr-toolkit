<#
.SYNOPSIS
    Creates the toolkit security role and assigns its privileges from schema.json.

.DESCRIPTION
    Privilege ids differ per environment, which is why this was originally a manual step.
    They can be read from entity metadata at run time, though, so nothing needs hard
    coding and the role comes out identical in every environment.

    Scripting it also reaches tables the role editor will not show you. queuemembership is
    an intersect entity, msdyn_ocliveworkitem is not surfaced, and environmentvariablevalue
    sits away from the tables you would look under. All three are reachable here.

    Safe to run repeatedly. The privilege set is replaced rather than appended, so the role
    always ends up matching schema.json exactly, including after a privilege is removed
    from it.

.EXAMPLE
    ./New-SecurityRole.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$SchemaFile = "$PSScriptRoot/schema.json",
    [string]$SolutionName = "PowerPeteIvrToolkitCore"
)

$ErrorActionPreference = "Stop"
$schema = Get-Content $SchemaFile -Raw | ConvertFrom-Json
$role = $schema.securityRole
$orgUrl = $EnvironmentUrl.TrimEnd('/')

. "$PSScriptRoot/Common.ps1"
$accessToken = Get-DataverseToken -Resource $orgUrl

$headers = @{
    Authorization      = "Bearer $accessToken"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    Accept             = "application/json"
    "Content-Type"     = "application/json; charset=utf-8"
}

function Invoke-Api {
    param([string]$Method, [string]$Path, $Body, [switch]$Representation)
    $uri = "$orgUrl$Path"
    $callHeaders = $headers.Clone()
    if ($Representation) { $callHeaders["Prefer"] = "return=representation" }
    try {
        if ($Body) {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $callHeaders -Body ($Body | ConvertTo-Json -Depth 10 -Compress)
        }
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $callHeaders
    }
    catch {
        $reason = if ($_.ErrorDetails.Message -match '"message":\s*"([^"]+)"') { $Matches[1] } else { $_.Exception.Message }
        throw "$Method $Path failed: $reason"
    }
}

# schema.json speaks in the words the role editor uses. Dataverse uses its own.
$depthMap = @{
    "Organization" = "Global"
    "ParentChild"  = "Deep"
    "BusinessUnit" = "Local"
    "User"         = "Basic"
}
$depthOrder = @("Global", "Deep", "Local", "Basic")

<#
.SYNOPSIS
    Returns the deepest depth at or below the one asked for that the privilege supports.
.DESCRIPTION
    Not every privilege can be granted at every depth. Stepping down rather than failing
    keeps a role usable on a table that only supports narrower access.
#>
function Resolve-Depth {
    param($Privilege, [string]$Wanted)
    $supported = @{
        Global = $Privilege.CanBeGlobal
        Deep   = $Privilege.CanBeDeep
        Local  = $Privilege.CanBeLocal
        Basic  = $Privilege.CanBeBasic
    }
    for ($i = [array]::IndexOf($depthOrder, $Wanted); $i -lt $depthOrder.Count; $i++) {
        if ($supported[$depthOrder[$i]]) { return $depthOrder[$i] }
    }
    return $null
}

# --- Role ---------------------------------------------------------------------
Write-Host "Security role" -ForegroundColor Cyan

$rootBu = (Invoke-Api -Method GET -Path '/api/data/v9.2/businessunits?$select=businessunitid&$filter=parentbusinessunitid eq null').value[0].businessunitid

$escapedName = $role.name -replace "'", "''"
$existing = (Invoke-Api -Method GET -Path "/api/data/v9.2/roles?`$select=roleid&`$filter=name eq '$escapedName'").value

if ($existing.Count -gt 0) {
    $roleId = $existing[0].roleid
    Write-Host "  = role '$($role.name)' exists" -ForegroundColor DarkGray
}
else {
    $created = Invoke-Api -Method POST -Path "/api/data/v9.2/roles" -Representation -Body @{
        name                      = $role.name
        description               = $role.description
        "businessunitid@odata.bind" = "/businessunits($rootBu)"
    }
    $roleId = $created.roleid
    Write-Host "  + role '$($role.name)'" -ForegroundColor DarkGray
}

# --- Privileges ---------------------------------------------------------------
Write-Host "`nResolving privileges" -ForegroundColor Cyan

$wanted = @()
$missing = @()

foreach ($entry in $role.privileges) {
    try {
        # Privileges is a complex property, not a navigation property, so it is selected
        # rather than expanded. Expanding it fails with 0x80060888 on every table.
        $meta = Invoke-Api -Method GET `
            -Path "/api/data/v9.2/EntityDefinitions(LogicalName='$($entry.table)')?`$select=LogicalName,Privileges"
    }
    catch {
        # Only a 404 means the table is genuinely absent. Reporting anything else as
        # missing sends you looking for a provisioning problem that is not there.
        if ($_.Exception.Message -match "\b404\b" -or $_.Exception.Message -match "Could not find") {
            Write-Host "  ! $($entry.table) does not exist in this environment" -ForegroundColor Yellow
            $missing += $entry.table
        }
        else {
            Write-Host "  ! $($entry.table): $($_.Exception.Message)" -ForegroundColor Yellow
            $missing += "$($entry.table): $($_.Exception.Message)"
        }
        continue
    }

    # Confirmed against a real environment, 2026-09-04. Some tables carry no privileges of
    # their own and are reached through a related table instead:
    #   queuemembership          intersect table, comes with queue and systemuser
    #   calendarrule             child of calendar, comes with prvReadCalendar
    #   environmentvariablevalue no privileges exist, comes with the definition
    # This is normal, not a provisioning gap, so it is reported without counting as a
    # failure. Do not "fix" it by inventing privilege names, there are none to grant.
    if ($meta.Privileges.Count -eq 0) {
        Write-Host "  . $($entry.table) has no privileges of its own, access comes from its related tables" -ForegroundColor DarkGray
        continue
    }

    $operations = [ordered]@{}
    if ($entry.read)   { $operations["Read"]   = $entry.read }
    if ($entry.create) { $operations["Create"] = if ($entry.create -is [string]) { $entry.create } else { "Organization" } }
    if ($entry.write)  { $operations["Write"]  = $entry.write }

    foreach ($operation in $operations.Keys) {
        $privilege = $meta.Privileges | Where-Object { $_.PrivilegeType -eq $operation } | Select-Object -First 1
        if (-not $privilege) {
            Write-Host "  ! $($entry.table) has no $operation privilege" -ForegroundColor Yellow
            $missing += "$($entry.table) ($operation)"
            continue
        }

        $depth = Resolve-Depth -Privilege $privilege -Wanted $depthMap[$operations[$operation]]
        if (-not $depth) {
            Write-Host "  ! $($privilege.Name) supports no depth at or below $($operations[$operation])" -ForegroundColor Yellow
            $missing += $privilege.Name
            continue
        }

        $wanted += @{ Depth = $depth; PrivilegeId = $privilege.PrivilegeId }
        Write-Host "  + $($privilege.Name) $depth" -ForegroundColor DarkGray

        # Activity tables share one set of privileges, so msdyn_ocliveworkitem resolves to
        # prvReadActivity and that grants read on every activity type in the organisation.
        # Wider than this toolkit needs, and there is no narrower privilege to ask for.
        if ($privilege.Name -eq "prvReadActivity") {
            Write-Host "    note: $($entry.table) is an activity table, so this grants read on all activities" -ForegroundColor Yellow
        }
    }
}

if ($wanted.Count -eq 0) { throw "No privileges resolved. Nothing to assign." }

# Replace rather than add, so a rerun converges on schema.json instead of accumulating.
Invoke-Api -Method POST -Path "/api/data/v9.2/roles($roleId)/Microsoft.Dynamics.CRM.ReplacePrivilegesRole" `
    -Body @{ Privileges = @($wanted) } | Out-Null

Write-Host "`n$($wanted.Count) privileges assigned to '$($role.name)'" -ForegroundColor Green

# --- Solution membership ------------------------------------------------------
try {
    Invoke-Api -Method POST -Path "/api/data/v9.2/AddSolutionComponent" -Body @{
        ComponentId           = $roleId
        ComponentType         = 20
        SolutionUniqueName    = $SolutionName
        AddRequiredComponents = $false
    } | Out-Null
    Write-Host "Added to solution $SolutionName" -ForegroundColor DarkGray
}
catch {
    Write-Host "Already a component of $SolutionName" -ForegroundColor DarkGray
}

if ($missing.Count -gt 0) {
    Write-Host "`n$($missing.Count) privilege(s) could not be assigned:" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host "A missing table usually means that feature is not provisioned here." -ForegroundColor Yellow
}

Write-Host "`nAssign the role to the application user the agent authenticates as." -ForegroundColor Gray
Write-Host "Do not substitute System Administrator." -ForegroundColor Gray
