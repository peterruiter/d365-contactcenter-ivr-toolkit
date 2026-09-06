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
  CCaaS_CreateSimpleProactiveDelivery   one delivery per record
    |
    v
  Proactive engagement, in whatever dial mode  ->  status Queued
    |
    v
  Representative accepts  ->  call placed  ->  status Completed
```

The API call is the part people assume is implicit and is not. Proactive engagement takes
its audience from a file upload, the CCaaS API, MCP or a Customer Insights journey. It
cannot see a custom table, so a promoted record with nothing dispatching it is a row that
says ready and is never read. Before 3.5.0 that was exactly what promotion did.

`Queued` means handed over, not dialled. Proactive engagement decides when the call goes
out inside the window it was given.

Owning the dialer would mean rebuilding capacity handling, presence awareness and
compliance. Proactive engagement already does all of that.

## Setup

### 1. Outbound calling

Configure an outbound profile with a voice queue and a capacity profile, and a phone
number enabled for outbound calling. Add representatives to the outbound capacity
profile.

### 2. Outbound workstream

Create a workstream with the Outbound option. You do not need its id: the Settings page
lists every active outbound workstream by name and writes the id for you.

### 3. Proactive engagement

This is what places the calls, and the toolkit will not work without it. Create it from
the workstream, so the workstream is filled in for you: **Copilot Service admin center** >
**Customer support** > **Workstreams** > your outbound workstream > **New proactive
engagement**.

The wizard has seven pages. Three settings on them are requirements of the toolkit. The
rest are yours.

**Audience.** Under **Select your audience**, choose **Contact Center**, then **CCaaS
API** as the intake method. This one is not optional: the toolkit dispatches through
`CCaaS_CreateSimpleProactiveDelivery`, and an engagement expecting a file upload or a
Customer Insights journey is not listening for that call.

**Details.** Set **Contact unique identifier** to **contactid**. The toolkit sends the
Dynamics contact GUID, so anything else will not match and the engagement will create a
duplicate contact for every callback. Pick the **Primary queue** that should handle the
callbacks.

**Everything else is your decision.** Dial mode, engagement type, priority, call order,
display numbers, reattempts, throttling and frequency limits are how your contact centre
chooses to run, and the toolkit has no view on any of it. It dispatches a delivery and the
engagement decides how the call is placed.

Two of those interact with settings on this side, so decide deliberately rather than by
accident:

| Engagement setting | Interaction |
|---|---|
| **Reattempts** | The engagement retries a delivery, and `pwrp_MaxCallbackAttempts` retries a request that came back as `NoAnswer`. Both configured means a caller is rung more times than either number says. Pick one to do the retrying and set the other to its minimum |
| **Frequency limits** and quiet hours | These can suppress a call the caller explicitly asked for at a time they chose. Reasonable for marketing outreach, less so for a booked callback |

Leave the engagement **active** when you are done. The toolkit finds it by looking for the
active engagement on the workstream, so a draft one is invisible to it.

Finally, note the engagement's name. If you ever create a second active engagement on the
same workstream, promotion stops rather than guessing which one rings your customers, and
`pwrp_ProactiveEngagementConfigId` is how you say.

### 4. Toolkit configuration

In the Contact Center IVR Toolkit app, go to **Settings**:

```
pwrp_EnableScheduledCallback = true
pwrp_OutboundWorkstreamId    = pick the workstream from step 2
pwrp_CallbackSlotMinutes     = 30
pwrp_MaxCallbackAttempts     = 3
pwrp_CallbackRetryMinutes    = 20
```

You do not configure the proactive engagement. A proactive engagement is created from a
workstream and carries it, so the toolkit finds the active one on
`pwrp_OutboundWorkstreamId` and dispatches through it.

`pwrp_ProactiveEngagementConfigId` exists only for the environment running more than one
active engagement on that workstream. Promotion refuses to guess in that case and names
them in the error, because choosing an engagement decides how customers are rung. The
Settings page lists them, so you pick rather than hunt for a GUID.

Then press **Run health check** on the same page. It fails when scheduled callback is on
and the workstream is not set, which is the mistake this ordering exists to catch.

Then set `pwrp_scheduledcallbackenabled = true` and a sensible `pwrp_slotcapacity` on
each queue profile that should offer it.

### 5. The promotion flow

Run `build/New-PromotionFlow.ps1`. It creates the flow, a connection reference, and adds
both to the solution.

```bash
pwsh build/New-PromotionFlow.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
```

Then bind the **Power Pete Dataverse** connection reference in the maker portal and switch
the flow on. It is created switched off on purpose: a flow promoting callbacks into a
workstream that is not configured yet fails every five minutes and buries its own run
history.

The flow is a recurrence and one unbound action calling `pwrp_PromoteDueCallbacks`. That is
the whole flow. It is deliberately a timer that calls one action: the date maths,
the slot window and the retry rules live in the plugin where they are unit tested and can
be read in a pull request. The same logic drawn as flow steps is unreviewable.

Turn it on after step 4. It does nothing while `pwrp_EnableScheduledCallback` is false.

`pwrp_HealthCheck` fails the **Callback promotion** check when scheduled callbacks are more
than fifteen minutes past their time and still `Requested`, which is what a missing flow
looks like from the outside.

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
