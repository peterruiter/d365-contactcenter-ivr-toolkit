# API reference

Every endpoint is an unbound Dataverse Custom API in the `pwrp_` namespace, and every one
is an **action**. Call it with a POST and a JSON body:

```
POST /api/data/v9.2/pwrp_GetQueueContext
{ "Queue": "HR" }
```

The read endpoints were functions until 2.0.0, called as
`GET /api/data/v9.2/pwrp_GetQueueContext(Queue='HR')`. A function is the honest
description of a read, but Copilot Studio's Dataverse connector offers only actions in
**Perform an unbound action**, so thirteen endpoints, including this one, could not be
reached from the route this toolkit tells people to use. Being callable beat being
correctly labelled.

## Shared outputs

Every endpoint returns these on top of its own outputs.

| Output | Type | Notes |
|---|---|---|
| `Success` | Boolean | False means handled but not completed. Read `ErrorCode` |
| `ErrorCode` | String | Stable. Branch on this, never on `ErrorMessage` |
| `ErrorMessage` | String | For logs and clarifying questions. Never read verbatim to a caller |
| `DurationMs` | Integer | Server side execution time. Watch it against your latency budget |

## Error codes

| Code | Meaning | What the agent should do |
|---|---|---|
| `QUEUE_NOT_FOUND` | No match | Ask the caller to name the team differently |
| `QUEUE_AMBIGUOUS` | Several close matches | Ask one clarifying question using the candidates |
| `HOURS_NOT_CONFIGURED` | No hours linked | Continue without an hours statement. Alert an admin |
| `METRICS_UNAVAILABLE` | Live read failed | Continue without wait times. Never mention a system problem |
| `CALLBACK_DISABLED` | Off for this queue | Offer voicemail or a transfer instead |
| `CALLBACK_SLOT_UNAVAILABLE` | Slot taken or invalid | Offer the next available slots |
| `CALLBACK_NOT_FOUND` | Lookup failed | Ask for the reference again |
| `INVALID_PHONE_NUMBER` | Failed validation | Ask for the number again, maximum twice |
| `INVALID_INPUT` | Missing or malformed input | Fix the agent. This is a wiring bug |
| `CONFIGURATION_ERROR` | Install incomplete | Run the health check |

---

## pwrp_GetQueueContext

The one to call. Opening state, wait band, outage message, callback availability and
a recommended action in one round trip.

**Input:** `Queue` (string, required) - name, alias or id.

**Outputs**

| Output | Type | Notes |
|---|---|---|
| `Context` | String | Full JSON payload |
| `QueueId` | String | Hold this in a variable and reuse it |
| `BroadcastMessage` | String | An outage or notice. Read it first, then still follow `RecommendedAction` |
| `IsOpen` | Boolean | |
| `WaitBand` | String | `Short`, `Moderate`, `Long`, `VeryLong` |
| `DirectCallbackAvailable` | Boolean | Offer a callback without a second lookup |
| `ScheduledCallbackAvailable` | Boolean | Whether a specific time can be booked |
| `RecommendedAction` | String | `Serve`, `OfferCallback`, `OfferVoicemail`, `AnnounceClosed` |
| `Speakable` | String | Read this |

Metrics are the only part allowed to fail silently. If the live read fails, the
context still returns with `WaitBand` defaulted to `Moderate` and the call continues.

**Recommended action logic**

```
outage message published        -> AnnounceOutage
queue closed                    -> AnnounceClosed
wait band Long or VeryLong
    and callback available      -> OfferCallback
    and callback not available  -> OfferVoicemail
otherwise                       -> Serve
```

---

## pwrp_ResolveQueue

Turns a spoken name into an id. Call once, reuse the id.

**Input:** `Queue` (string, required)

**Outputs:** `QueueId`, `QueueName`, `SpeakableName`, `ChannelType`, `Locale`

---

## pwrp_GetQueues

Lists active queues. Cached, so cheap.

**Input:** `ChannelType` (string, optional) - `Voice`, `Messaging`, `Record`

**Outputs:** `Queues` (JSON array), `Count`, `Speakable`

---

## pwrp_GetQueueHours

**Inputs:** `Queue` (required), `FromDate` (optional, defaults today), `Days`
(optional, 1 to 31, defaults 1)

**Outputs:** `Hours` (JSON array of days with windows), `Speakable`

Use `Days = 1` for "are you open today" and `Days = 7` for "what are your hours this
week". Holiday exceptions are already applied.

---

## pwrp_IsQueueOpen

**Inputs:** `Queue` (required), `AtUtc` (optional, defaults now)

**Outputs:** `IsOpen`, `Reason` (`Open`, `Closed`, `Holiday`, `OutsideHours`),
`NextOpenUtc`, `NextCloseUtc`, `Speakable`

Pass `AtUtc` to validate a callback time the caller proposes.

---

## pwrp_GetNextOpenTime

**Input:** `Queue` (required)

**Outputs:** `IsOpenNow`, `NextOpenUtc`, `Speakable`

Looks 14 days ahead, so it survives a long holiday closure.

---

## pwrp_GetQueueMetrics

**Input:** `Queue` (required)

**Outputs**

| Output | Notes |
|---|---|
| `WaitingNow` | Segments currently waiting |
| `LongestWaitSeconds` | Longest live wait right now |
| `AverageWaitSeconds` | Trailing average over `pwrp_MetricsWindowMinutes` |
| `EstimatedWaitSeconds` | Waiting divided by available, times the trailing average |
| `RepresentativesAvailable` | Queue members in an Available presence |
| `RepresentativesOnline` | Queue members signed in, any presence |
| `WaitBand` | Give the caller this |
| `Speakable` | And this |

`RepresentativesOnline` on its own is a weak signal. Somebody signed in but Busy
cannot take the call. Use `RepresentativesAvailable`.

---

## pwrp_CheckCallbackEligibility

**Input:** `Queue` (required)

**Outputs:** `DirectCallbackAvailable`, `ScheduledCallbackAvailable`, `AnyAvailable`

Skip this if you already have it from `pwrp_GetQueueContext`, which returns
`DirectCallbackAvailable` and `ScheduledCallbackAvailable` directly.

---

## pwrp_GetCallbackSlots

**Inputs:** `Queue` (required), `Days` (optional, 1 to 14, defaults 3),
`MaxResults` (optional, defaults 6), `PreferredStartUtc` (optional)

**Outputs:** `Slots` (JSON), `Count`, `IsExactMatch`, `Speakable` (first three only)

Slots fall inside opening hours and respect `pwrp_slotcapacity`. Offer three over the
phone. Six and the caller loses track.

Send `PreferredStartUtc` when the caller names a time rather than picking from the list.
The slots nearest it come back instead of the earliest, which is rarely the same set: a
caller who asks for Thursday afternoon does not want three times tomorrow morning.

`IsExactMatch` is true when the requested time falls inside the first slot returned. A
slot is a window, so asking for 12:05 and being offered the 12:00 to 12:15 slot counts:
the caller is rung when they asked to be. When it is false, the toolkit found the nearest
it has and the agent should say so before booking.

The nearest slots are chosen by distance from the preference and then returned in time
order. Reading them back nearest first gives "quarter to three, quarter past three, half
two", which sounds like a mistake.

A preference outside the `Days` window returns the nearest inside it. Widen `Days` if the
agent should honour "next week".

---

## pwrp_CreateCallback

**Inputs**

| Input | Required | Notes |
|---|---|---|
| `Queue` | Yes | |
| `PhoneNumber` | Yes | Any format. Normalised to E.164 |
| `Mode` | No | `Direct` or `Scheduled`. Defaults to `Direct` |
| `RequestedStartUtc` | For Scheduled | Must match an available slot |
| `ContactId` | No | |
| `ConversationId` | No | Ties the callback to the conversation |
| `ContextJson` | No | Anything the representative should see before dialling |

**Outputs:** `Callback` (JSON), `CallbackId`, `Reference`, `IsExisting`, `Status`,
`Speakable`

`IsExisting` is true when the request already existed and was returned rather than
created. Without it a repeat is indistinguishable from a fresh booking, and an agent
cannot tell a caller they already have one.

Idempotent per queue and number. A repeat call while a callback is open returns the
existing one rather than creating a duplicate. Voice agents retry on timeouts, and
callers repeat themselves, so this is not optional.

`Reference` is six characters drawn from an alphabet with no lookalikes, so it
survives being read over a phone line.

---

## pwrp_GetCallbackStatus

**Inputs:** one of `Reference`, `PhoneNumber`, `CallbackId`

**Outputs:** `Callback` (JSON), `Status`, `Attempts`

Statuses: `Requested`, `Queued`, `Dialling`, `Completed`, `Cancelled`, `Failed`, `NoAnswer`

---

## pwrp_CancelCallback / pwrp_RescheduleCallback

Cancel takes `CallbackId`. Reschedule takes `Queue`, `CallbackId` and `NewStartUtc`,
and validates the new time against available slots.

---

## pwrp_ValidatePhoneNumber

**Inputs:** `PhoneNumber` (required), `Queue` (optional), `CountryCode` (optional)

Send the number exactly as the caller said it, here and to `pwrp_CreateCallback`. Both
normalise it themselves. `Speakable` spells it back in the caller's own format, so
someone who said "0653740141" hears that and not a country code they never gave.

**Outputs:** `IsValid`, `E164`, `NumberType` (`Mobile`, `Landline`, `Unknown`),
`Reason`, `Speakable`

Country is resolved most specific first: an explicit `CountryCode`, then the queue's
`pwrp_countrycode`, then `pwrp_DefaultCountryCode`. Send `Queue` rather than
`CountryCode` in an agent. A market is a property of the queue, not of the agent, and an
agent that pins one country gets the wrong answer for every other one.

This only matters for a number given in national format. `+32 475 123456` and
`0032 475 123456` carry their own country and are read correctly whatever is configured.
`0475 123456` read against the Dutch code becomes `+31475123456`, which is nine digits
after a valid country code, so it is returned as a valid Dutch landline with no error at
all. That is the failure this prevents.

`Speakable` is the number spelled digit by digit, so a confirmation is actually
verifiable. Handles `06 12 34 56 78`, `0031612345678`, `+31 6 1234 5678` and the
other shapes speech recognition produces.

---

## pwrp_GetBroadcastMessage

**Input:** `Queue` (required)

**Outputs:** `HasMessage`, `Speakable`

---

## pwrp_LogIvrOutcome

**Inputs:** `Outcome` (required), `Queue`, `Intent`, `ConversationId`, `AgentName`,
`DurationSeconds`, `ContextJson`

**Output:** `OutcomeId`

Outcomes: `Contained`, `Escalated`, `CallbackBooked`, `Abandoned`, `ClosedAnnouncement`

Call it on every conversation, including the ones that went nowhere. Without it you
cannot answer the only question the client asks after go live.

---

## pwrp_HealthCheck

No inputs. Returns `Checks` (JSON), `Passed`, `FailureCount`.

Run after install, after every solution upgrade, and after every Contact Center
release wave update.
