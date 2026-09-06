# Overview

## The problem

A Copilot Studio agent sitting in front of Dynamics 365 Contact Center cannot answer
the questions callers actually ask. Are you open. How long is the wait. Can you call
me back. The data exists in Dataverse, but not in a shape an agent can use, and not
fast enough for voice if you fetch it piece by piece.

This toolkit closes that gap.

## What it is

A managed Dataverse solution containing Custom APIs, config tables and a model driven
app. No Azure hosting, no external services. The plugin runs next to the data, which
is where the latency budget is won.

## Architecture

```
  Copilot Studio agent
        |
        |  MCP server  (generative / real-time agents)
        |  Connector   (classic topic based agents)
        v
  +-----------------------------------------+
  |  Custom APIs  (pwrp_*)                  |   <- the contract, versioned
  +-----------------------------------------+
  |  Services                               |
  |    QueueResolver     HoursService       |
  |    MetricsReader     CallbackService    |
  |    SpeakableFormatter                   |
  +-----------------------------------------+
  |  Data                                   |
  |    pwrp_* config tables  (yours)        |
  |    queue, msdyn_operatinghour, calendar |
  |    msdyn_queueextension  (platform)     |
  +-----------------------------------------+
```

Two things about this shape matter.

**The contract layer is separate from the data layer.** Live metrics come from tables
that carry no API guarantee. When a release wave moves them, you fix one file and
every agent built on the toolkit keeps working.

**Both agent types share one core.** Real-time agents get few, fat, well described
tools. Classic agents get granular deterministic actions. Same plugins underneath.

## Design decisions worth knowing

### One composite call, not nine

`pwrp_GetQueueContext` returns opening state, wait band, outage message, callback
availability and a recommended action. In a real-time voice agent, each separate tool
call is silence the caller hears. Use the granular endpoints for edge cases.

### Bands, not numbers

Every metric endpoint returns raw seconds for supervisors and a `WaitBand` for
callers. Read the band. Callers hang up on numbers.

### Names, not GUIDs

A speech driven IVR never has a queue id. Name resolution with aliases and fuzzy
matching is the primary path. When two queues match closely the toolkit returns
`QUEUE_AMBIGUOUS` so the agent asks one clarifying question rather than picking wrong.

### Every response is speakable

Structured data plus a phrase in the queue locale. `09:00:00 - 17:30:00` read aloud
sounds like a machine. This is the part clients rebuild badly every time.

### Errors are data

An expected failure returns `Success = false` with a stable `ErrorCode`. A voice agent
never sees a platform fault, and never tells a caller that a system is down.

### Callback is mostly not a build

Direct callback is native. Configure it as a queue overflow action and the platform
handles the hold and the dial. The toolkit only reports eligibility and status.
Scheduled callback is a real build, but proactive engagement places the calls. Owning a
dialer would be the wrong call. The dial mode is the engagement's, not the toolkit's, so
whether the representative or the customer is reached first is your choice and not a
property of this.

### Why not customer-first direct callback

[Customer-first direct callback](https://learn.microsoft.com/dynamics365/contact-center/administer/configure-customer-first-callback)
is the native feature closest to this, and it is worth being precise about what actually
differs.

Not the dial order. Customer-first rings the customer before reserving a representative,
and so does this whenever the engagement uses Copilot, progressive or predictive mode.
Preview is the mode that reserves the representative first. That is a setting on the
proactive engagement either way, not a difference between the two features.

What differs is where the callback comes from and what the caller can do with it.
Customer-first is an overflow action: the caller is already queueing, the queue is already
overflowing, and the request keeps its place and is dialled when it reaches the front. The
caller never picks a time, because there is no time to pick. The promise is "we will not
make you hold", not "we will ring you at three".

| | Customer-first direct callback | Scheduled callback here |
|---|---|---|
| Triggered by | Queue overflow | Anything the agent decides |
| When the call goes out | When the request reaches the front of the queue | In the window the caller chose |
| Caller picks a time | No | Yes, from offered slots |
| Change it afterwards | No | Reschedule or cancel by reference |
| Works out of hours | No, the caller has to be in a queue | Yes |
| Needs a Copilot Studio agent | Yes, and enabling is irreversible | No |

That last row matters more than it looks. Enabling customer-first cannot be undone, the
first profile is applied automatically to every queue already using direct callback as an
overflow action, and it consumes Copilot credits. It is a decision, not a setting.

The two are complements. Use the native one for the overflow path, where it handles the
queue position and the retry logic for you. Use this for the caller who rings out of
hours, or does not want to hold at all, or wants a call on Tuesday morning and then rings
back on Monday to move it. None of those start with a queue.

## What it does not do

- Place calls. Proactive engagement does that.
- Replace real-time dashboards. Supervisors keep those.
- Guarantee metrics across release waves. See [ALM and support](10-alm-and-support.md).
- Speak languages beyond nl-NL and en-GB without adding resource entries.
