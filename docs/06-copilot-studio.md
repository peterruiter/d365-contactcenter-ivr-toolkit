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

Every parameter has to be set to something. The designer will not save a blank, and there
is no way to omit one, so an optional parameter needs a value that means "not supplied".
Two behaviours in the plugin make that safe:

- A string that is empty or only whitespace is treated as absent, so the default applies
- A date of `0001-01-01T00:00:00Z` is treated as absent, for the same reason

So a placeholder is not a workaround here, it is the supported way to say nothing. The
values in the tables below are chosen on that basis and none of them writes bad data.

Never fill an optional parameter with AI just to have something in it. A model asked for
a country code will offer `+31`, `NL` or `Netherlands`, and the toolkit wants `31`. A
model asked for a duration will invent one.

Leave **Completion** on **Don't respond** for every tool. That hands the result back to
the model, which then follows `RecommendedAction` and reads `Speakable`, which is the
whole point of the composite endpoint. Anything that replies automatically reads the raw
output to the caller, so they hear "WaitingNow 14" instead of a wait band, and the
branching in `RecommendedAction` never happens. Both are rules this toolkit exists to
enforce.

Add these nine and nothing else. The first five are blocks below, one each, because they
carry the conversation and you will paste their descriptions. The other four are the rest
of the callback lifecycle plus hours, and they fit in one table.

Each block is the tool name, what it takes, and the description to paste. The description is not documentation, it is the only thing the
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
| `Queue` | Dynamically fill with AI | The same queue name sent to `pwrp_GetQueueContext`. The country comes from the queue profile, so one agent serves every market |
| `CountryCode` | Custom value `-` | A value that cannot be a country code is ignored, so `Queue` decides. Set a real code here only to force one country regardless of queue |

**Description:**

> Normalises a spoken or typed phone number to E.164 and returns a digit by digit spelling for confirmation.

### pwrp_GetCallbackSlots

| Parameter | Fill using | Value |
|---|---|---|
| `Queue` | Dynamically fill with AI | The same queue name sent to `pwrp_GetQueueContext` |
| `Days` | Custom value `3` | How far ahead to look. Three days is long enough to find a slot and short enough that the first ones offered are the useful ones |
| `MaxResults` | Custom value `3` | The endpoint defaults to six. Six is fine on a screen and wrong on a phone: a caller cannot hold six times in their head, and reading them turns a thirty second booking into two minutes |
| `PreferredStartUtc` | Dynamically fill with AI | A time the caller asked for, when they name one instead of picking from the list. Leave it to the model to fill only when the caller says a time: unfilled it comes through as not supplied and the earliest slots come back, which is what you want for "whenever" |

**Description:**

> Bookable callback windows inside opening hours, with remaining capacity. Send PreferredStartUtc when the caller names a time and the nearest available slots come back instead of the earliest. Offer at most three over the phone.

Only useful where scheduled callback is on. It needs both the
`pwrp_EnableScheduledCallback` setting and `pwrp_scheduledcallbackenabled` on the queue
profile, and it is off by default. Add the tool anyway: an agent that has it can say
scheduled callback is not available for this queue, and an agent without it says it
cannot retrieve the slots, which sounds like an outage and leaves the caller waiting for
a fix that is not coming.

### pwrp_CreateCallback

| Parameter | Fill using | Value |
|---|---|---|
| `Queue` | Dynamically fill with AI | |
| `PhoneNumber` | Dynamically fill with AI | The number as the caller said it, the same string you sent to `pwrp_ValidatePhoneNumber`. Not the `E164`, and never rebuilt from the digits you read back |
| `Mode` | Dynamically fill with AI | `Direct` or `Scheduled`, whichever the caller chose. Safe to let the model pick, because `pwrp_CreateCallback` refuses `Scheduled` on a queue that does not allow it and returns `CALLBACK_DISABLED`. Pin it to `Direct` only if you deliberately never offer booked times |
| `RequestedStartUtc` | Dynamically fill with AI | The slot the caller chose, exactly as `pwrp_GetCallbackSlots` returned it. Ignored when `Mode` is `Direct`, and a time that is not one of the returned slots is rejected |
| `ConversationId` | Custom value `System.Conversation.Id` | Ties the callback to the conversation, which is what makes it traceable afterwards |
| `ContactId` | Custom value `-` | Leave it. The toolkit matches the contact from the number the caller gave, which works whether or not the conversation recognised them. Bind `=Global.msdyn_CustomerId` only if you want the recognised customer to win over the number, and note it is dropped when it turns out to be an account rather than a contact |
| `ContextJson` | Custom value `{}`, or dynamically filled with AI | `{}` books a callback that tells the representative nothing. Filling it with a sentence on what the caller wanted is what makes the callback better than a missed call |

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
| `DurationSeconds` | Custom value `0` | Zero means unknown. Do not let the model guess a duration, it will |
| `ContextJson` | Custom value `{}` | |

**Description:**

> Records what the agent did so containment and deflection can be reported. Call once at the end of every conversation.

### The rest of the callback lifecycle, and hours

Add these four as well. Booking a callback and then being unable to say where it is,
move it or cancel it is half a feature: the caller rings back, gets an agent that cannot
answer, and asks for a person. Hours is here because "when are you open" is the second
thing callers ask after "put me through".

| Tool | Fill using | Description |
|---|---|---|
| `pwrp_GetCallbackStatus` | `Reference` and `PhoneNumber` by AI, whichever the caller offers. `CallbackId` custom `-`, a caller never has one | Looks up a callback by reference, phone number or id. |
| `pwrp_CancelCallback` | `CallbackId` by AI, from the booking earlier in the call or from `pwrp_GetCallbackStatus` | Cancels an open callback request. |
| `pwrp_RescheduleCallback` | All three by AI. `NewStartUtc` must be a slot `pwrp_GetCallbackSlots` returned | Moves a scheduled callback to a different available slot. |
| `pwrp_GetQueueHours` | `Queue` by AI. `Days` custom `7`. `FromDate` custom `0001-01-01T00:00:00Z`, which the plugin reads as today | Opening hours for a queue across a date range, holiday exceptions included. |

Nine is the budget, not a starting point. An agent given nineteen tools picks badly, and
on a voice call every wrong pick is silence. Adding a tenth means arguing one of these
out first.

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

### A diagnostics path, for a test agent

`samples/copilot-studio/debug-mode-instructions.md` adds a mode that reads the raw values
back rather than the caller facing phrasing: the resolved queue id, the broadcast message,
the wait band alongside the seconds behind it, representatives online and available,
`RecommendedAction`, and `DurationMs` against the latency budget. It can also book and
cancel callbacks in either mode.

It is quicker than reading a trace log and it exercises the same path a caller takes,
which a script calling the Web API does not.

Append it below the normal instructions, and take it out before a real caller can reach
the agent. It deliberately breaks the two rules the toolkit exists to enforce, reading
numbers of waiting callers and seconds of waiting out loud. A caller who hears "fourteen
people ahead of you" hangs up, which is the whole reason `WaitBand` exists.

The nine core tools already cover the callback lifecycle and hours, so a diagnostics
agent can exercise all of it as shipped. Two more are worth adding to this agent only:

| Tool | Fill using | For |
|---|---|---|
| `pwrp_GetQueueMetrics` | `Queue` by AI | The seconds and counts behind the band |
| `pwrp_HealthCheck` | no inputs | Validating an install by voice |

Adding them to the agent callers reach would be a mistake. `pwrp_GetQueueMetrics` returns
the raw seconds and counts that `WaitBand` exists to keep out of a caller's ear, and
`pwrp_HealthCheck` reports on the install rather than on anything a caller asked about.

Leave `pwrp_LogIvrOutcome` off this agent entirely. Told plainly not to log a diagnostics
call, a model logged one anyway, and the row sits in the containment reporting as though a
caller had been served. Removing the tool is the only reliable control.

No change to any core tool. `Mode` on `pwrp_CreateCallback` is already filled by AI, so
both modes can be tested as they ship.

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
