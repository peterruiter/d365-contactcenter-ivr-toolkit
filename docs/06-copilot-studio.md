# Wiring it into Copilot Studio

Two agent types, one set of Custom APIs, two ways to expose them.

| Agent type | How to expose | Why |
|---|---|---|
| Real-time voice (speech to speech) | MCP server, or Dataverse connector unbound action | Few, fat tools. Descriptions drive orchestration |
| Classic topic based | Custom connector from `connector/apiDefinition.swagger.json` | Deterministic calls. Explicit inputs matter more |

## Real-time voice agents

### Adding the tools

Tools > Add a tool > Model Context Protocol, and point at the toolkit MCP server.
Or add the Dataverse connector and use **Perform an unbound action** per API, which
needs no Azure and is the shorter path.

Every endpoint is an action, so all of them appear in that picklist. They were functions
until 2.0.0, and functions are not offered there at all, which made the endpoint this
toolkit is built around unreachable from its own default route.

Add these four and nothing else:

- `pwrp_GetQueueContext`
- `pwrp_ValidatePhoneNumber`
- `pwrp_CreateCallback`
- `pwrp_LogIvrOutcome`

Add the rest only when a scenario needs them. Every extra tool is another thing the
orchestrator can pick wrongly.

### Instructions

Copy `samples/copilot-studio/realtime-agent-instructions.md` into the Instructions
box and replace `{ORGANISATION}`.

### Latency

Use a static greeting. A dynamic greeting with variables adds latency to the very
first thing the caller hears, which is the worst place to spend it.

Budget 500 ms per tool call. Check `DurationMs` on every response during testing. If
a call is consistently over, look at `pwrp_MetricsCacheSeconds` first.

Do not chain calls. One call, then speak, then decide. Three lookups before the first
word is three gaps of silence.

### The instruction that matters most

> Follow `RecommendedAction`. Do not decide for yourself.

Without it, the model reasons its way to a different answer on every call. With it,
the branching is deterministic and the wording stays natural. That split is the point
of the composite endpoint.

## Classic topic based agents

Import `connector/apiDefinition.swagger.json` as a custom connector, or add the
Dataverse connector and bind unbound actions per topic.

See `samples/copilot-studio/classic-topic-notes.md` for topic structures covering
opening hours, wait time and callback.

Two rules:

- Hold `QueueId` in a variable after the first resolve. Re-resolving a name every
  turn adds round trips you do not need.
- Bind messages to `Speakable`, not to the raw metric outputs.

## Authentication

The agent authenticates as an application user holding the **Power Pete IVR Reader**
role. Create both with:

```powershell
./build/New-ApplicationUser.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
```

That role grants read on queues, hours, metrics tables and the toolkit config tables,
create on callbacks and outcomes, and read on `plugintype` and `pluginassembly`. The last
two are not obvious: the platform reads them to resolve a Custom API to its code, and
without them no endpoint runs at all.

Prove the role before wiring the agent, because as an administrator everything passes
whether the role is right or not:

```powershell
./build/Test-Endpoints.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com `
    -TenantId <tenant> -ClientId <app> -ClientSecret <secret>
```

Do not give the agent System Administrator. The toolkit is designed to run on a
minimal role, and an administrator hides every privilege it is missing until a client
environment finds it.

## Testing

Test with deliberately vague utterances, not clean ones. "Can I speak to someone about
my bill", not "billing queue". That is what exposes missing aliases.

Watch the plugin trace log during testing. Every fuzzy match is an alias you should
have configured, and the toolkit traces them under `[pwrp]`.

Trace logging is off in a new environment. Turn it on first, in the Power Platform admin
centre under the environment's settings, or nothing is recorded and a failure inside the
metrics reader stays invisible by design.

Test these specifically:

| Scenario | What should happen |
|---|---|
| Ambiguous queue name | `QUEUE_AMBIGUOUS`, agent asks one question |
| Outside opening hours | `AnnounceClosed`, next open time read out |
| During a holiday | Holiday phrasing, not the generic closed phrasing |
| Metrics unavailable | Call continues, no mention of wait times |
| Broadcast message active | Read first, before anything else |
| Same callback requested twice | Existing callback returned, no duplicate |
| Number given as "oh six, one two, three four..." | Normalised and confirmed digit by digit |

## Deployment across environments

Custom API names are stable, so an agent solution moves between environments without
rebinding. Environment variables carry the per environment configuration.

Version the agent solution alongside the toolkit version it was built against. When
you upgrade the toolkit, run the health check before you promote the agent.
