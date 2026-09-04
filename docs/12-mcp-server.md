# MCP server

Optional. Decide whether you need it before you deploy anything.

## Do you need it?

| Route | Azure needed | Latency | Tool discovery | When to pick it |
|---|---|---|---|---|
| Dataverse connector, unbound actions | No | Lowest | Manual per action | Default. Start here |
| Custom connector | No | Low | Manual | Classic agents, Power Automate |
| MCP server | Container App | One extra hop | Dynamic | Several agents, or you want an audit point |

Most deployments do not need it. The Dataverse connector calls the same Custom APIs
with one fewer hop and no infrastructure to own.

Deploy the MCP server when:

- Several agents across teams share the toolkit and you want one place to change the
  tool surface
- You want an audit or rate limiting point in front of Dataverse
- You want tools to appear in agents automatically when the contract changes

Do not deploy it because MCP is newer. The extra hop costs you 30 to 80 ms on every
call, and on voice that is real.

## What it does

A streamable HTTP MCP server that proxies `tools/list` and `tools/call` to the toolkit
Custom APIs. Stateless. No database. Roughly 300 lines.

The tool catalogue is generated from `build/customapis.json` at startup, so the MCP
surface cannot drift from the contract.

## Exposed tools

Nine by default:

```
pwrp_GetQueueContext        pwrp_GetCallbackSlots
pwrp_GetQueueHours          pwrp_CreateCallback
pwrp_GetNextOpenTime        pwrp_GetCallbackStatus
pwrp_ValidatePhoneNumber    pwrp_CancelCallback
                            pwrp_LogIvrOutcome
```

The rest exist but stay hidden. An agent given nineteen tools picks badly, and every
extra tool is another thing the orchestrator can get wrong.

Override with `Mcp__ExposedTools` as a comma separated list. Private APIs are never
exposed regardless.

## Deploy

```bash
az acr build --registry myregistry --image pwrp-ivr-mcp:1.0.0 \
  --file src/PowerPete.IvrToolkit.Mcp/Dockerfile .

az deployment group create \
  --resource-group rg-pwrp \
  --template-file mcp/infra/main.bicep \
  --parameters \
      dataverseEnvironmentUrl=https://contoso.crm4.dynamics.com \
      containerImage=myregistry.azurecr.io/pwrp-ivr-mcp:1.0.0 \
      mcpApiKey=$(openssl rand -base64 32)
```

The deployment outputs `principalId`. Create a Dataverse application user for that
managed identity and give it **Power Pete IVR Reader**. Nothing more.

## Wire into Copilot Studio

Tools > Add a tool > Model Context Protocol. Point at the `mcpEndpoint` output. Add the
API key as a header named `x-pwrp-key`.

## Operational notes

**Keep one replica warm.** `minReplicas` is 1 in the template. A cold start on a live
call is unacceptable, and the saving from scaling to zero is a false economy.

**Same region as Dataverse.** The proxy hop is only cheap if it is not crossing a
continent.

**15 second timeout.** Hardcoded in the client. A voice agent must never hang on a
call, so the server returns a `TIMEOUT` error code and lets the agent carry on.

**Errors are shaped like toolkit errors.** An upstream fault comes back as
`Success: false` with `UPSTREAM_ERROR`, not a raw 500. The agent handles it the same
way it handles any other error code, and never tells a caller a system is down.

**`isError` stays false for expected failures.** `QUEUE_AMBIGUOUS` is an answer, not an
error. Setting `isError` would make the agent retry rather than ask a clarifying
question.

## Monitoring

Application Insights is wired in. Every tool call logs name, status and elapsed
milliseconds.

```kusto
traces
| where message has "returned"
| extend tool = tostring(customDimensions.Tool),
         elapsed = todouble(customDimensions.Elapsed)
| summarize p50 = percentile(elapsed, 50),
            p95 = percentile(elapsed, 95),
            calls = count()
  by tool
| order by p95 desc
```

Alert on the 95th percentile above 800 ms. That is your voice budget being spent.
