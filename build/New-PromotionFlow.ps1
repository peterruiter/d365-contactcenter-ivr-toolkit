<#
.SYNOPSIS
    Creates the Power Pete Promote Due Callbacks flow and adds it to the solution.

.DESCRIPTION
    Scheduled callback books a request and nothing dispatches it. A recurrence flow calling
    pwrp_PromoteDueCallbacks is what moves a due record from Requested to Queued and hands
    it to the outbound workstream. Without it, records sit at Requested for ever and the
    only person who finds out is the caller who was never rung.

    The flow was documented as shipping in the solution for several versions and did not
    exist. This creates it through the Web API rather than by hand editing solution XML,
    for the same reason every other component here is created that way: the export then
    produces the XML, so it is correct by construction rather than by my guess at the
    schema.

    The flow is deliberately thin. A recurrence and one unbound action. Every decision it
    could contain, the slot window, the retry gap, what counts as due, lives in the plugin
    where it is unit tested and readable in a pull request. The same logic drawn as flow
    steps cannot be reviewed.

    It is created switched off. Turning it on is a deliberate act after the environment
    variables are set, because a flow that promotes callbacks into a workstream that is not
    configured fails every five minutes and fills the run history with noise.

    A connection reference is created alongside it if one does not already exist. Binding it
    to a real connection is done once in the maker portal, which is how connection
    references work in every solution: the reference travels, the connection does not.

    Safe to run repeatedly. An existing flow is left alone apart from its definition, so a
    flow you have switched on stays on.

.EXAMPLE
    ./New-PromotionFlow.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
    [string]$SolutionName = "PowerPeteIvrToolkitCore",
    [string]$FlowName = "Power Pete Promote Due Callbacks",
    [int]$IntervalMinutes = 5
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Common.ps1"
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl

$connectorId = "/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps"
$referenceName = "pwrp_sharedcommondataserviceforapps_promotecallbacks"

# --- Connection reference -----------------------------------------------------
# The flow names a connection reference rather than a connection. The reference is the
# solution component and moves between environments; the connection behind it is bound
# once per environment by a person with credentials.
$existingRef = (Invoke-Dataverse -Method GET -Path ("/api/data/v9.2/connectionreferences" +
    "?`$select=connectionreferenceid,connectionreferencelogicalname" +
    "&`$filter=connectionreferencelogicalname eq '$referenceName'")).value

if ($existingRef.Count -gt 0) {
    Write-Host "  = connection reference already present" -ForegroundColor DarkGray
}
else {
    Invoke-Dataverse -Method POST -Path "/api/data/v9.2/connectionreferences" -SolutionName $SolutionName -Body @{
        connectionreferencelogicalname = $referenceName
        connectionreferencedisplayname = "Power Pete Dataverse"
        connectorid                    = $connectorId
    } | Out-Null
    Write-Host "  + connection reference created" -ForegroundColor Green
    Write-Host "    Bind it to a connection in the maker portal before switching the flow on." -ForegroundColor Yellow
}

# --- Flow definition ----------------------------------------------------------
# Kept as an object and serialised once, so the shape is readable here rather than being a
# wall of escaped JSON. clientdata is a string containing JSON, not nested JSON, which is
# the part that catches people out.
$definition = [ordered]@{
    '$schema'      = "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"
    contentVersion = "1.0.0.0"
    parameters     = [ordered]@{
        '$connections' = [ordered]@{ defaultValue = @{}; type = "Object" }
        '$authentication' = [ordered]@{ defaultValue = @{}; type = "SecureObject" }
    }
    triggers       = [ordered]@{
        "Every_$($IntervalMinutes)_minutes" = [ordered]@{
            type       = "Recurrence"
            recurrence = [ordered]@{ frequency = "Minute"; interval = $IntervalMinutes }
        }
    }
    actions        = [ordered]@{
        "Promote_due_callbacks" = [ordered]@{
            type    = "OpenApiConnection"
            inputs  = [ordered]@{
                host       = [ordered]@{
                    connectionName = "shared_commondataserviceforapps"
                    operationId    = "PerformUnboundAction"
                    apiId          = $connectorId
                }
                parameters = [ordered]@{ actionName = "pwrp_PromoteDueCallbacks" }
                authentication = "@parameters('`$authentication')"
            }
            runAfter = @{}
            # Five minutes is the cadence, so a run that cannot reach Dataverse should give
            # up well inside that. Overlapping runs would promote the same record twice.
            limit   = [ordered]@{ timeout = "PT2M" }
        }
    }
}

$clientData = [ordered]@{
    properties = [ordered]@{
        connectionReferences = [ordered]@{
            shared_commondataserviceforapps = [ordered]@{
                runtimeSource = "embedded"
                connection    = [ordered]@{ connectionReferenceLogicalName = $referenceName }
                api           = [ordered]@{ name = "shared_commondataserviceforapps" }
            }
        }
        definition = $definition
    }
    schemaVersion = "1.0.0.0"
}

$body = @{
    category      = 5          # Modern Flow
    type          = 1          # Definition, not an activation or a template
    primaryentity = "none"     # A recurrence is not bound to a table
    name          = $FlowName
    description   = "Calls pwrp_PromoteDueCallbacks every $IntervalMinutes minutes. All logic lives in the plugin."
    clientdata    = ($clientData | ConvertTo-Json -Depth 25 -Compress)
}

# --- Create or update ---------------------------------------------------------
$existing = (Invoke-Dataverse -Method GET -Path ("/api/data/v9.2/workflows" +
    "?`$select=workflowid,name,statecode" +
    "&`$filter=category eq 5 and name eq '$($FlowName -replace "'", "''")'")).value

if ($existing.Count -gt 0) {
    $flowId = $existing[0].workflowid

    # A running flow must be taken out of service before its definition can be replaced,
    # and put back the way it was found. Leaving someone's live flow switched off because
    # a definition changed is not an acceptable side effect of running this.
    $wasOn = $existing[0].statecode -eq 1
    if ($wasOn) {
        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/workflows($flowId)" `
            -Body @{ statecode = 0; statuscode = 1 } | Out-Null
    }

    Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/workflows($flowId)" `
        -SolutionName $SolutionName -Body $body | Out-Null

    if ($wasOn) {
        Invoke-Dataverse -Method PATCH -Path "/api/data/v9.2/workflows($flowId)" `
            -Body @{ statecode = 1; statuscode = 2 } | Out-Null
    }

    Write-Host "  = flow updated$(if ($wasOn) { ' and switched back on' })" -ForegroundColor DarkGray
}
else {
    $created = Invoke-Dataverse -Method POST -Path "/api/data/v9.2/workflows" `
        -SolutionName $SolutionName -Body $body
    Write-Host "  + flow created, switched off" -ForegroundColor Green
}

Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  1. Bind the Power Pete Dataverse connection reference in the maker portal."
Write-Host "     Do this before opening the flow in the designer. Until it is bound the"
Write-Host "     designer cannot resolve the action and reports an XRM API error, and"
Write-Host "     saving from that state rewrites the connection reference away." -ForegroundColor Yellow
Write-Host "  2. Set pwrp_EnableScheduledCallback and pwrp_OutboundWorkstreamId on the Settings page."
Write-Host "  3. Turn the flow on."
Write-Host "  4. Run pwrp_HealthCheck. The Callback promotion check reads overdue records,"
Write-Host "     so it tells you whether the flow is actually doing anything."
