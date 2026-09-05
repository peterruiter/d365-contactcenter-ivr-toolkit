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

In **Perform an unbound action**, set Environment to your organisation and Action Name to
the API. Both are **Custom value**. The **Action parameters** input stays unresolved until
an action is chosen, then it takes that action's inputs.

Each parameter is then either filled by the model or pinned to a value. The rule is
simple: anything that comes out of the conversation is filled by AI, anything that is a
policy decision is a custom value. A policy pinned as a custom value cannot be talked out
of by a caller.

Leave **Completion** on **Don't respond** for every tool. That hands the result back to
the model, which then follows `RecommendedAction` and reads `Speakable`, which is the
whole point of the composite endpoint. Anything that replies automatically reads the raw
output to the caller, so they hear "WaitingNow 14" instead of a wait band, and the
branching in `RecommendedAction` never happens. Both are rules this toolkit exists to
enforce.

Add these four and nothing else. Each block is the tool name, what it takes, and the
description to paste. The description is not documentation, it is the only thing the
model sees when it decides what to call, so paste it as written. See
[14 Tool descriptions](14-tool-descriptions.md) before you reword one.

### pwrp_GetQueueContext

| Parameter | Fill using | Value |
|---|---|---|
| `Queue` | Dynamically fill with AI | The queue name as the caller said it. Aliases and fuzzy matching are the toolkit's job, not the model's |

**Description:**

> Returns opening state, live wait band, outage message, callback availability and a recommended action in one call. Use this at the start of a voice conversation instead of several separate lookups.

### pwrp_ValidatePhoneNumber

| Parameter | Fill using | Value |
|---|---|---|
| `PhoneNumber` | Dynamically fill with AI | Whatever the caller said, in any format |
| `CountryCode` | Leave unset | Falls back to `pwrp_DefaultCountryCode`. Setting it here hard codes a country into the agent |

**Description:**

> Normalises a spoken or typed phone number to E.164 and returns a digit by digit spelling for confirmation.

### pwrp_CreateCallback

| Parameter | Fill using | Value |
|---|---|---|
| `Queue` | Dynamically fill with AI | |
| `PhoneNumber` | Dynamically fill with AI | The `E164` that `pwrp_ValidatePhoneNumber` returned, not what the caller said |
| `Mode` | Custom value `Direct` | Pin it unless the agent really offers booked slots. A model that can choose `Scheduled` will sometimes choose it on a queue that does not allow it |
| `RequestedStartUtc` | Dynamically fill with AI | Only when `Mode` is `Scheduled`. Leave unset otherwise |
| `ConversationId` | Custom value `System.Conversation.Id` | Ties the callback to the conversation, which is what makes it traceable afterwards |
| `ContactId`, `ContextJson` | Leave unset | |

**Description:**

> Books a callback. Mode Direct queues it for the next free representative. Mode Scheduled books a specific slot. Repeated calls for the same number and queue return the existing request rather than creating a duplicate.

### pwrp_LogIvrOutcome

| Parameter | Fill using | Value |
|---|---|---|
| `Outcome` | Dynamically fill with AI | One of `Contained`, `Escalated`, `CallbackBooked`, `Abandoned`, `ClosedAnnouncement`. Put the list in the description so the model cannot invent a sixth |
| `Queue` | Dynamically fill with AI | |
| `Intent` | Dynamically fill with AI | What the caller wanted, in a few words. This is what makes the reporting worth reading |
| `ConversationId` | Custom value `System.Conversation.Id` | |
| `AgentName` | Custom value | The agent's name. It is the same on every call, so pinning it stops the model inventing one |
| `DurationSeconds`, `ContextJson` | Leave unset | |

**Description:**

> Records what the agent did so containment and deflection can be reported. Call once at the end of every conversation.

### Add these only when a scenario asks for them

| Tool | Fill using | Add it when | Description |
|---|---|---|---|
| `pwrp_GetCallbackSlots` | `Queue` by AI. `MaxResults` custom `3`, because three is what a caller can hold in their head. `Days` unset | Callers pick a time | Bookable callback windows inside opening hours, with remaining capacity. Offer at most three over the phone. |
| `pwrp_GetCallbackStatus` | `Reference` and `PhoneNumber` by AI, whichever the caller offers. `CallbackId` unset, a caller never has one | Callers ask where their callback is | Looks up a callback by reference, phone number or id. |
| `pwrp_CancelCallback` | `CallbackId` by AI, from the booking earlier in the call | Callers can cancel | Cancels an open callback request. |
| `pwrp_RescheduleCallback` | All three by AI. `NewStartUtc` must be a slot `pwrp_GetCallbackSlots` returned | Callers can move a slot | Moves a scheduled callback to a different available slot. |
| `pwrp_GetQueueHours` | `Queue` by AI. `Days` custom `7`. `FromDate` unset, it defaults to today | Someone asks about a week, not about now | Opening hours for a queue across a date range, holiday exceptions included. |
Leave the rest out. `pwrp_ResolveQueue`, `pwrp_IsQueueOpen`, `pwrp_GetNextOpenTime`,
`pwrp_GetQueueMetrics`, `pwrp_CheckCallbackEligibility` and `pwrp_GetBroadcastMessage` all
return something `pwrp_GetQueueContext` already gave you. Adding them invites three calls
where one would do, and each call is silence the caller hears. `pwrp_GetQueues` lists
queues, which no caller wants. `pwrp_HealthCheck` is for operations.

`pwrp_PromoteDueCallbacks` and `pwrp_RecordCallbackOutcome` are private and do not appear
in the picklist at all. They belong to the promotion flow.

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
