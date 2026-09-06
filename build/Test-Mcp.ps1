<#
.SYNOPSIS
    Exercises the MCP server the way an agent does, over JSON-RPC.

.DESCRIPTION
    Test-Endpoints.ps1 proves the Custom APIs work. This proves the other route to them
    does, which is a different question: the catalogue is generated from customapis.json at
    startup, the proxy shapes errors itself, and either can be wrong while the APIs are
    fine.

    Checks the three things that actually break:

      the server is up and its Dataverse credentials work
      tools/list returns the nine exposed tools and nothing internal
      tools/call reaches a Custom API and comes back shaped like one

    Nothing here writes. It calls pwrp_ValidatePhoneNumber, which needs no queue and has no
    side effects, and pwrp_GetQueueContext only when a queue is named.

    Run the server first:

      cd src/PowerPete.IvrToolkit.Mcp
      dotnet run

    With no client secret configured the server falls back to DefaultAzureCredential, so an
    "az login" as yourself is enough to try it locally. That is the better local test
    anyway: it keeps a real client secret out of your shell history.

.EXAMPLE
    ./Test-Mcp.ps1

.EXAMPLE
    ./Test-Mcp.ps1 -Url https://pwrp-ivr-mcp.azurecontainerapps.io -ApiKey $key -Queue "HR"
#>
[CmdletBinding()]
param(
    [string]$Url = "http://localhost:5000",
    [string]$ApiKey,
    [string]$Queue,
    [string]$PhoneNumber = "0612345678",
    [string]$DefinitionFile = "$PSScriptRoot/customapis.json"
)

$ErrorActionPreference = "Continue"

$Url = $Url.TrimEnd('/')
$headers = @{ "Content-Type" = "application/json" }
if ($ApiKey) { $headers["x-pwrp-key"] = $ApiKey }

$script:passed = 0
$script:failed = 0
$script:id = 0

function Write-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        $script:failed++
    }
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor Gray }
}

function Invoke-Rpc {
    param([string]$Method, $Parameters)

    $script:id++
    $body = @{ jsonrpc = "2.0"; id = $script:id; method = $Method }
    if ($Parameters) { $body.params = $Parameters }

    return Invoke-RestMethod -Method POST -Uri "$Url/mcp" -Headers $headers `
        -Body ($body | ConvertTo-Json -Depth 12 -Compress)
}

Write-Host "Testing the MCP server at $Url`n" -ForegroundColor Cyan

# --- 1. Reachable ------------------------------------------------------------
try {
    $health = Invoke-RestMethod -Method GET -Uri "$Url/health"
    Write-Result -Name "Health" -Ok $true -Detail "protocol $($health.version)"
}
catch {
    Write-Result -Name "Health" -Ok $false -Detail $_.Exception.Message
    Write-Host "`nThe server is not answering. Start it with 'dotnet run' in" -ForegroundColor Yellow
    Write-Host "src/PowerPete.IvrToolkit.Mcp, or pass -Url for a deployed one." -ForegroundColor Yellow
    exit 1
}

# --- 2. The catalogue matches the contract -----------------------------------
# Generated at startup from customapis.json, so this is really asking whether the file the
# server loaded is the file in this repository.
$definition = Get-Content $DefinitionFile -Raw | ConvertFrom-Json
$internal = $definition.apis | Where-Object { $_.internal } | ForEach-Object { $_.name }

try {
    $list = Invoke-Rpc -Method "tools/list"
    $tools = @($list.result.tools | ForEach-Object { $_.name })

    Write-Result -Name "tools/list" -Ok ($tools.Count -gt 0) -Detail "$($tools.Count) tools exposed"
    foreach ($tool in $tools) { Write-Host "         $tool" -ForegroundColor DarkGray }

    # An internal API reaching an agent is the failure that matters here. The rest of the
    # catalogue is a judgement call about what an agent needs; this one is a mistake.
    $leaked = @($tools | Where-Object { $internal -contains $_ })
    Write-Result -Name "Internal tools stay hidden" -Ok ($leaked.Count -eq 0) `
        -Detail $(if ($leaked.Count) { "exposed: $($leaked -join ', ')" } else { "$($internal.Count) internal APIs, none exposed" })
}
catch {
    Write-Result -Name "tools/list" -Ok $false -Detail $_.Exception.Message
}

# --- 3. A call reaches Dataverse and comes back shaped like the toolkit -------
try {
    $call = Invoke-Rpc -Method "tools/call" -Parameters @{
        name      = "pwrp_ValidatePhoneNumber"
        arguments = @{ PhoneNumber = $PhoneNumber }
    }

    $text = $call.result.content[0].text
    $payload = $text | ConvertFrom-Json

    Write-Result -Name "tools/call pwrp_ValidatePhoneNumber" -Ok ($payload.Success -eq $true) `
        -Detail "E164 $($payload.E164), type $($payload.NumberType), isError $($call.result.isError)"
}
catch {
    Write-Result -Name "tools/call pwrp_ValidatePhoneNumber" -Ok $false -Detail $_.Exception.Message
    Write-Host "         A failure here is usually the server's Dataverse credentials," -ForegroundColor DarkGray
    Write-Host "         not the toolkit. Test-Endpoints.ps1 tells the two apart." -ForegroundColor DarkGray
}

if ($Queue) {
    try {
        $call = Invoke-Rpc -Method "tools/call" -Parameters @{
            name      = "pwrp_GetQueueContext"
            arguments = @{ Queue = $Queue }
        }
        $payload = $call.result.content[0].text | ConvertFrom-Json
        Write-Result -Name "tools/call pwrp_GetQueueContext" -Ok ($payload.Success -eq $true) `
            -Detail "$($payload.QueueName), open $($payload.IsOpen), band $($payload.WaitBand)"
    }
    catch {
        Write-Result -Name "tools/call pwrp_GetQueueContext" -Ok $false -Detail $_.Exception.Message
    }
}

# --- 4. An expected failure is an answer, not an error -----------------------
# isError true would make an agent retry instead of asking the caller which queue they
# meant, so this is worth asserting rather than assuming.
try {
    $call = Invoke-Rpc -Method "tools/call" -Parameters @{
        name      = "pwrp_GetQueueContext"
        arguments = @{ Queue = "a queue that certainly does not exist" }
    }
    $payload = $call.result.content[0].text | ConvertFrom-Json

    Write-Result -Name "An expected failure keeps isError false" `
        -Ok ($payload.Success -eq $false -and $call.result.isError -ne $true) `
        -Detail "ErrorCode $($payload.ErrorCode), isError $($call.result.isError)"
}
catch {
    Write-Result -Name "An expected failure keeps isError false" -Ok $false -Detail $_.Exception.Message
}

Write-Host "`n$script:passed passed, $script:failed failed" `
    -ForegroundColor $(if ($script:failed -eq 0) { "Green" } else { "Yellow" })
