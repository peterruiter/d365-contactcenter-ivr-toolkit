# Scheduled callback

Direct callback needs almost nothing. Scheduled callback is a real build. This page
covers both so you can tell them apart.

## Direct callback

Native. The caller keeps their place, hangs up, and the platform calls them back when
their work item reaches position one. The dial uses preview mode, so a representative
accepts before the number is dialled.

**Setup:** Copilot Service admin centre > your voice queue > overflow handling. Add a
condition, set the action to direct callback.

**Toolkit involvement:** none, beyond reporting. Set
`pwrp_directcallbackenabled = true` on the queue profile so the agent knows it may
offer it, and `pwrp_GetCallbackStatus` for "where is my callback".

Do not rebuild this. If direct callback covers the requirement, stop here.

## Scheduled callback

The caller picks a time. That is not native, so the toolkit builds it. It still does
not build a dialer.

```
  Agent
    |  pwrp_GetCallbackSlots  -> available windows
    |  pwrp_CreateCallback    -> writes pwrp_callbackrequest
    v
  pwrp_callbackrequest  (status Requested)
    |
    |  scheduled flow, every 5 minutes
    |  promotes due records
    v
  Outbound workstream  ->  proactive engagement, preview dial mode
    |
    v
  Representative accepts  ->  call placed  ->  status Completed
```

Owning the dialer would mean rebuilding capacity handling, presence awareness and
compliance. Proactive engagement already does all of that.

## Setup

### 1. Outbound calling

Configure an outbound profile with a voice queue and a capacity profile, and a phone
number enabled for outbound calling. Add representatives to the outbound capacity
profile.

### 2. Outbound workstream

Create a workstream with the Outbound option. Note its id.

### 3. Proactive engagement

Configure preview dial mode against that workstream. Preview, not progressive or
predictive. The representative sees the caller's context before the dial, which is
the whole point of a scheduled callback.

### 4. Toolkit configuration

```
pwrp_EnableScheduledCallback = true
pwrp_OutboundWorkstreamId    = <workstream guid>
pwrp_CallbackSlotMinutes     = 30
pwrp_MaxCallbackAttempts     = 3
pwrp_CallbackRetryMinutes    = 20
```

Then set `pwrp_scheduledcallbackenabled = true` and a sensible `pwrp_slotcapacity` on
each queue profile that should offer it.

### 5. The promotion flow

Ships in the solution as **Power Pete Promote Due Callbacks**. Runs every five minutes,
picks up `Requested` records due within the slot window, moves them to `Queued` and
hands them to the outbound workstream.

Turn it on after step 4. It does nothing while `pwrp_EnableScheduledCallback` is false.

## The slot model

A slot is a window inside opening hours with a capacity cap. Without the cap, an IVR
will happily book fifty callbacks into one thirty minute window and the queue will
drown at 10:00.

Set `pwrp_slotcapacity` to what the queue can genuinely absorb on top of inbound.
Start low. Two per slot on a queue of eight representatives is not conservative, it
is realistic.

Slots never fall outside opening hours. `pwrp_GetCallbackSlots` builds them from the
same hours resolver the rest of the toolkit uses, so a holiday closure removes them
automatically.

## Retry policy

Decide this before go live. It is where these projects go wrong.

| Setting | Question to answer |
|---|---|
| `pwrp_MaxCallbackAttempts` | How many times before you give up |
| `pwrp_CallbackRetryMinutes` | How long between attempts |
| Voicemail behaviour | Leave a message, or count it as an attempt and retry |
| Terminal state | Does a failed callback become an SMS, a case, or nothing |

The default is three attempts, twenty minutes apart, then `Failed`. That is a starting
point, not an answer. Ask the client.

## Deduplication

`pwrp_CreateCallback` returns the existing request when one is already open for the
same queue and number. Voice agents retry on timeouts and callers repeat themselves,
so without this a nervous caller ends up with three callbacks and the client ends up
with a complaint.

## Reporting

`pwrp_callbackrequest` carries status, attempts, requested time and the conversation
id. Join it to `pwrp_ivroutcome` on the conversation id for containment reporting
that includes callbacks.

The two numbers a client will ask for:

- Callbacks booked as a share of calls that hit a long wait
- Callbacks completed on the first attempt
