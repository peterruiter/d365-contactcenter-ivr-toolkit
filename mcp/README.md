# MCP server

Optional. Read [docs/12-mcp-server.md](../docs/12-mcp-server.md) before you deploy it.

## Deploy

```bash
# 1. Build and push
az acr build --registry myregistry --image pwrp-ivr-mcp:1.0.0 --file src/PowerPete.IvrToolkit.Mcp/Dockerfile .

# 2. Deploy
az deployment group create \
  --resource-group rg-pwrp \
  --template-file mcp/infra/main.bicep \
  --parameters \
      dataverseEnvironmentUrl=https://contoso.crm4.dynamics.com \
      containerImage=myregistry.azurecr.io/pwrp-ivr-mcp:1.0.0 \
      mcpApiKey=$(openssl rand -base64 32)
```

The deployment outputs `principalId`. Create an application user in Dataverse for that
identity and give it the **Power Pete IVR Reader** role. Nothing more.

## Run locally

```bash
cd src/PowerPete.IvrToolkit.Mcp
dotnet user-secrets set "Dataverse:EnvironmentUrl" "https://contoso.crm4.dynamics.com"
dotnet user-secrets set "Dataverse:TenantId" "<tenant guid>"
dotnet user-secrets set "Dataverse:ClientId" "<app registration id>"
dotnet user-secrets set "Dataverse:ClientSecret" "<secret>"
dotnet run
```

```bash
# List tools
curl -s localhost:5000/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq

# Call one
curl -s localhost:5000/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
       "params":{"name":"pwrp_GetQueueContext","arguments":{"Queue":"billing"}}}' | jq
```

## Which tools are exposed

Nine by default. An agent given nineteen tools picks badly, so the rest stay hidden
until you ask for them via `Mcp__ExposedTools`.

The catalogue is generated from `build/customapis.json` at startup, so the MCP surface
cannot drift from the Custom API contract. Change the contract, rebuild, done.

APIs marked `internal` in the contract (`pwrp_PromoteDueCallbacks`,
`pwrp_RecordCallbackOutcome`) are never exposed. They are for flows, not agents.
