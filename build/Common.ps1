<#
.SYNOPSIS
    Shared authentication helpers for the environment scripts.

.DESCRIPTION
    Dot source this from any script that talks to a Dataverse environment:

        . "$PSScriptRoot/Common.ps1"

    Two things live here, both about not asking for credentials that are already held.
#>

function ConvertFrom-SecureStringToPlain {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Secure)
    return [System.Net.NetworkCredential]::new('', $Secure).Password
}

$script:DataverseOrgUrl = $null
$script:DataverseHeaders = $null

<#
.SYNOPSIS
    Prepares the Web API transport for an environment. Call once, before Invoke-Dataverse.
#>
function Connect-Dataverse {
    param([Parameter(Mandatory = $true)][string]$EnvironmentUrl)

    $script:DataverseOrgUrl = $EnvironmentUrl.TrimEnd('/')
    $token = Get-DataverseToken -Resource $script:DataverseOrgUrl
    $script:DataverseHeaders = @{
        Authorization      = "Bearer $token"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        Accept             = "application/json"
        "Content-Type"     = "application/json; charset=utf-8"
    }
}

<#
.SYNOPSIS
    Prepares the transport as an application user, using a client secret.

.DESCRIPTION
    This is how an agent and the MCP server actually connect, and it is the only way to
    find out whether the minimal security role is really sufficient. Running as yourself
    proves nothing, because you are an administrator.

    Nothing is cached. A client secret belongs in whatever is holding it already, not in a
    file this script writes.
#>
function Connect-DataverseAsApp {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret
    )

    $script:DataverseOrgUrl = $EnvironmentUrl.TrimEnd('/')

    $token = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "$script:DataverseOrgUrl/.default"
        }

    $script:DataverseHeaders = @{
        Authorization      = "Bearer $($token.access_token)"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        Accept             = "application/json"
        "Content-Type"     = "application/json; charset=utf-8"
    }

    Write-Host "Connected as application $ClientId" -ForegroundColor DarkGray
}

<#
.SYNOPSIS
    Calls the Dataverse Web API.

.DESCRIPTION
    These scripts were written against "pac env http", which is not a command in any
    published version of the CLI, so every call through it failed. This replaces it.

    Failures throw with the message Dataverse actually returned. A non-zero exit code from
    a native command does not throw in PowerShell, which is how the original calls managed
    to fail silently inside a try/catch and still report success.

    Contention is retried rather than thrown. An environment where somebody is importing a
    solution rejects a publish outright, and a schema customisation elsewhere can drop the
    session mid statement. Neither is a fault in the call and neither applies a partial
    change: the operation is refused before it starts. What they do is kill a long
    provisioning run at step forty, which is expensive to be halfway through.

    A retry is only safe because of that. Do not widen the pattern to cover errors where
    the platform may have already done some of the work.
#>
function Invoke-Dataverse {
    param(
        [string]$Method = "GET",
        [Parameter(Mandatory = $true)][string]$Path,
        $Body,
        [string]$SolutionName,
        [switch]$Representation,
        [int]$Attempts = 6,
        # Extra transient pattern for this call only. PublishXml is the reason it exists:
        # it answers "An unexpected error occurred" when the environment is busy, which is
        # far too vague to retry on in general but is safe on an operation that is
        # idempotent by definition. Do not pass it on anything that writes.
        [string]$RetryOn
    )

    if (-not $script:DataverseHeaders) { throw "Call Connect-Dataverse before Invoke-Dataverse." }

    # Per call, so a refresh is available again on the next one. A long script can outlive
    # a token more than once.
    $script:DataverseRetriedAuth = $false

    $headers = $script:DataverseHeaders.Clone()
    if ($SolutionName) { $headers["MSCRM.SolutionUniqueName"] = $SolutionName }
    if ($Representation) { $headers["Prefer"] = "return=representation" }

    # An import can run for minutes, so the waits are long enough to outlast a small one
    # without pretending this is a substitute for waiting. Total is a little over four
    # minutes across six attempts.
    $transient = "because there is another \[[A-Za-z]+\] running|" +
                 "installation or removal of another solution|" +
                 "database session was disconnected|" +
                 "schema customization request is currently being ran"
    if ($RetryOn) { $transient = "$transient|$RetryOn" }

    for ($attempt = 1; ; $attempt++) {
        try {
            if ($null -ne $Body) {
                $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 15 -Compress }
                return Invoke-RestMethod -Method $Method -Uri "$script:DataverseOrgUrl$Path" -Headers $headers -Body $json
            }
            return Invoke-RestMethod -Method $Method -Uri "$script:DataverseOrgUrl$Path" -Headers $headers
        }
        catch {
            $detail = $_.ErrorDetails.Message
            $reason = if ($detail -match '"message":\s*"([^"]+)"') { $Matches[1] } else { $_.Exception.Message }

            # An access token lasts about an hour and the headers are built once, at
            # Connect-Dataverse. A session left open across a lunch break then fails on
            # its next call with a bare 401, which reads like a permissions problem and is
            # not one. The refresh token is cached, so this costs a round trip and no sign
            # in. Once only: a 401 that survives a fresh token is a real 401.
            if (-not $script:DataverseRetriedAuth -and
                ($_.Exception.Response.StatusCode.value__ -eq 401 -or $reason -match "401 \(Unauthorized\)")) {
                $script:DataverseRetriedAuth = $true
                Write-Host "  ... token expired, refreshing" -ForegroundColor DarkGray
                Connect-Dataverse -EnvironmentUrl $script:DataverseOrgUrl
                $headers = $script:DataverseHeaders.Clone()
                if ($SolutionName) { $headers["MSCRM.SolutionUniqueName"] = $SolutionName }
                if ($Representation) { $headers["Prefer"] = "return=representation" }
                continue
            }

            if ($attempt -lt $Attempts -and ($detail -match $transient -or $reason -match $transient)) {
                $wait = 15 * $attempt
                Write-Host "  ... environment busy, waiting $wait s and retrying ($attempt of $($Attempts - 1))" -ForegroundColor DarkGray
                Start-Sleep -Seconds $wait
                continue
            }

            if ($reason -match $transient) {
                throw "$Method $Path failed: $reason`n" +
                      "Another solution operation is still running. Check Solution History in the " +
                      "maker portal, wait for it to finish, then run this script again."
            }
            throw "$Method $Path failed: $reason"
        }
    }
}

<#
.SYNOPSIS
    Selects a pac auth profile, creating one only when it does not already exist.

.DESCRIPTION
    "pac auth create" runs an interactive sign in every time it is called, even when a
    profile for the same environment is already stored. Scripts that call it
    unconditionally therefore re-authenticate on every run. This checks first.

    A profile is only reused when it points at the same organisation, so switching
    environments still signs in rather than silently targeting the previous one.
#>
function Connect-Pac {
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )

    $orgHost = ([Uri]$EnvironmentUrl).Host
    $existing = & pac auth list 2>&1 | Where-Object {
        $_ -match [regex]::Escape($ProfileName) -and $_ -match [regex]::Escape($orgHost)
    }

    if ($existing) {
        & pac auth select --name $ProfileName | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Using pac profile $ProfileName" -ForegroundColor DarkGray
            return
        }
    }

    & pac auth create --environment $EnvironmentUrl --name $ProfileName
    if ($LASTEXITCODE -ne 0) { throw "Could not authenticate to $EnvironmentUrl" }
    & pac auth select --name $ProfileName | Out-Null
}

function Save-DataverseToken {
    param([string]$CacheFile, $Token)

    $dir = Split-Path $CacheFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    try {
        [PSCustomObject]@{
            ExpiresOn    = (Get-Date).AddSeconds([int]$Token.expires_in)
            AccessToken  = (ConvertTo-SecureString $Token.access_token -AsPlainText -Force)
            RefreshToken = if ($Token.refresh_token) { ConvertTo-SecureString $Token.refresh_token -AsPlainText -Force } else { $null }
        } | Export-Clixml -Path $CacheFile
    }
    catch {
        # Export-Clixml protects a SecureString with DPAPI, which is Windows only. Losing
        # the cache costs a sign in on the next run, so it is not worth failing over.
        Write-Host "Could not cache the token, you will be asked to sign in again" -ForegroundColor DarkGray
    }
}

<#
.SYNOPSIS
    Returns an access token for the Dataverse Web API, reusing a cached one when possible.

.DESCRIPTION
    pac has no command that returns a token scoped to a Dataverse organisation.
    "pac auth token" mints one for the Power Platform API, which Dataverse rejects with
    401, so scripts calling the Web API directly have to acquire their own.

    The token and its refresh token are cached under the user's local application data,
    encrypted with DPAPI. The device code prompt therefore appears on the first run
    against an environment and then not again until the refresh token expires, which is
    weeks rather than minutes.
#>
function Get-DataverseToken {
    param([Parameter(Mandatory = $true)][string]$Resource)

    # Well-known public client for interactive Dataverse access, the one XrmToolBox and
    # most Dataverse PowerShell tooling uses. No app registration needed.
    $clientId = "51f81489-12ee-4a9e-aaae-a2591f45987d"
    $authority = "https://login.microsoftonline.com/organizations/oauth2/v2.0"
    $scope = "$Resource/.default offline_access"

    $cacheFile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) `
        "PowerPete/token-$(([Uri]$Resource).Host).xml"

    $cached = $null
    if (Test-Path $cacheFile) {
        try { $cached = Import-Clixml $cacheFile } catch { $cached = $null }
    }

    # Five minutes of headroom, so a long run cannot expire halfway through.
    if ($cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        Write-Host "Using cached Dataverse token" -ForegroundColor DarkGray
        return (ConvertFrom-SecureStringToPlain $cached.AccessToken)
    }

    if ($cached -and $cached.RefreshToken) {
        try {
            $refreshed = Invoke-RestMethod -Method Post -Uri "$authority/token" -Body @{
                grant_type    = "refresh_token"
                client_id     = $clientId
                refresh_token = (ConvertFrom-SecureStringToPlain $cached.RefreshToken)
                scope         = $scope
            }
            Save-DataverseToken -CacheFile $cacheFile -Token $refreshed
            Write-Host "Refreshed Dataverse token, no sign in needed" -ForegroundColor DarkGray
            return $refreshed.access_token
        }
        catch {
            # Refresh tokens expire and can be revoked. Fall through to a fresh sign in.
        }
    }

    $device = Invoke-RestMethod -Method Post -Uri "$authority/devicecode" -Body @{
        client_id = $clientId
        scope     = $scope
    }
    Write-Host "`n$($device.message)`n" -ForegroundColor Yellow

    $deadline = (Get-Date).AddSeconds($device.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $device.interval
        try {
            $token = Invoke-RestMethod -Method Post -Uri "$authority/token" -Body @{
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                client_id   = $clientId
                device_code = $device.device_code
            }
            Save-DataverseToken -CacheFile $cacheFile -Token $token
            return $token.access_token
        }
        catch {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
            if ($errBody.error -eq "authorization_pending") { continue }
            throw "Sign in failed: $($errBody.error_description)"
        }
    }

    throw "Device code sign in timed out."
}
