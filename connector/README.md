# Custom connector

For classic topic based agents, and for Power Automate flows that need the toolkit.

Real-time voice agents should use the Dataverse connector's unbound actions or the
[MCP server](../mcp/README.md) instead. Both save a hop.

## The swagger is generated

`apiDefinition.swagger.json` is generated from `build/customapis.json`, so the connector
surface cannot drift from the Custom API contract. Do not hand edit it.

Regenerate after any contract change:

```bash
python3 build/Build-Swagger.py
```

Private operations (`pwrp_PromoteDueCallbacks`, `pwrp_RecordCallbackOutcome`) are
excluded. They are for flows, not agents.

## Deploy

```bash
# Replace {organisation} in the host and resource uri first
pac connector create --settings-file connector/settings.json --environment <environment id>
```

Or import `apiDefinition.swagger.json` through the maker portal, then set the OAuth
resource uri to your Dataverse environment url.

## Update an existing connector

```bash
pac connector update --settings-file connector/settings.json --environment <environment id>
```

Updating in place preserves connections and the bindings any agent already has. Deleting
and recreating does not, and every agent then needs rewiring.
