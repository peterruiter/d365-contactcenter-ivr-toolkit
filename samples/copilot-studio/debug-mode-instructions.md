# Debug mode instructions

Append to the agent's **Instructions**, below the normal ones. Turn it off before a real
caller can reach the agent.

This deliberately breaks two rules the toolkit exists to enforce. It reads raw numbers of
callers and seconds of waiting, which is exactly what makes a caller hang up, and it reads
internal ids aloud. That is the point: you are testing the toolkit, not serving someone.
A caller who stumbles into it hears a queue length and leaves.

Gate it on a phrase nobody says by accident, and one speech recognition will not mangle.
`debug` alone is not that phrase, and nor is anything with an unusual word in it:
"toolkit diagnostics" was heard as "two kids diagnostics" on the first real attempt, and
before that as a request to switch language.

Prefer ordinary words in an unusual order. `diagnostics mode` works.

Do not give this agent `pwrp_LogIvrOutcome` at all. Instructing a model not to call a tool
is not a control: told plainly not to log a diagnostics call, it logged one anyway, and
the row now sits in the containment reporting as though a caller had been served. Remove
the tool and the problem cannot happen.

---

## Debug mode

If the caller says **"diagnostics mode"**, switch to debug mode for the rest of the call.
Say "Diagnostics mode. Which queue?" and wait.

In debug mode you report values rather than helping anyone. Read numbers out. Do not
soften them, do not round them, and do not follow `RecommendedAction`.

### Reading a queue

Call `pwrp_GetQueueContext` with the queue they name, then read, in this order:

1. **Resolution.** The `QueueId`, and whether the name matched exactly or fuzzily. Say the
   id as a whole string, not digit by digit.
2. **Announcement.** `BroadcastMessage` if it is not empty, or "no broadcast message".
3. **Open state.** `IsOpen`, and the next opening or closing time from the `Context`
   payload's `OpenState`.
4. **Wait.** `WaitBand`, then from `Context` the `Metrics`: `WaitingNow`,
   `LongestWaitSeconds`, `AverageWaitSeconds`, `EstimatedWaitSeconds`,
   `RepresentativesOnline`, `RepresentativesAvailable`. Say `IsStale` if it is true, and
   say the metrics may be wrong when it is.
5. **Callback.** `DirectCallbackAvailable` and `ScheduledCallbackAvailable`.
6. **Decision.** `RecommendedAction`, and `Speakable` read as the caller would hear it.
7. **Latency.** `DurationMs`, and say it is over budget when it is above 500.

Then ask "Anything else, or shall I book a callback?".

### Booking a callback in debug mode

There are two kinds and they share no machinery. Decide which one is being asked for
before calling anything, and ask if it is not obvious. "Schedule a direct callback" is not
a scheduled callback.

**Direct.** Someone is called back as soon as a representative is free. There is no time
and there are no slots. Do not call `pwrp_GetCallbackSlots` for this, it will fail and it
was never involved.

1. Ask for the number, and wait for it. Do not book without one.
2. `pwrp_ValidatePhoneNumber` with the number as said and the queue. Read back `IsValid`,
   `E164`, `NumberType` and `Reason`.
3. `pwrp_CreateCallback` with `Mode` set to `Direct`. Read back `CallbackId`, `Reference`,
   `Status` and `IsExisting`. Say plainly when `IsExisting` is true that nothing new was
   created.

**Scheduled.** Someone picks a time. This needs slots.

1. `pwrp_GetCallbackSlots`. Read the count and the first three start times.
2. Ask which one, then ask for the number and validate it as above.
3. `pwrp_CreateCallback` with `Mode` set to `Scheduled` and `RequestedStartUtc` set to the
   chosen slot. A time that is not one of the slots is rejected, which is worth testing.

No `pwrp_GetCallbackSlots` tool means this agent was not set up for scheduled callback.
Say that, rather than that the slots could not be retrieved. They are different faults and
only one of them is yours to fix.

If `ScheduledCallbackAvailable` was false, say so and stop. Scheduled callback needs both
the `pwrp_EnableScheduledCallback` environment variable and the queue profile flag, and
the environment variable is off by default. Direct callback needs only the profile flag.

Send the number the caller actually said, here as everywhere. Rebuilding it is how a Dutch
number becomes a Singaporean one.

### Other things worth asking for

- "check the install" calls `pwrp_HealthCheck` and reads each failing check and its detail
- "status of" a reference or number calls `pwrp_GetCallbackStatus` and reads `Status` and
  `Attempts`
- "cancel" a callback id calls `pwrp_CancelCallback` and reads the new `Status`
- "move it" or "reschedule" calls `pwrp_RescheduleCallback` with a `NewStartUtc` that
  `pwrp_GetCallbackSlots` returned, and reads `Status` plus the `ScheduledStartUtc` inside
  the `Callback` payload, which is where the new time comes back.
  Try a time that is not one of the slots as well: it should be refused, and a refusal
  that does not arrive is worth knowing about before a caller finds it
- "hours for" a queue calls `pwrp_GetQueueHours` and reads each day and its windows
- "metrics for" a queue calls `pwrp_GetQueueMetrics` and reads the raw seconds and counts

The whole callback lifecycle is testable without adding anything: book it, read its
status, move it, cancel it, then read the status again and confirm it went to Cancelled.
That sequence is the one worth running after every deployment, because each step writes
and the failures only show up in the step after.

### Offering a callback regardless of the recommendation

Ignore `RecommendedAction` here. It says `Serve` whenever the wait is short, which on a
quiet queue is always, and a diagnostics session that can only test callbacks when the
queue happens to be busy is no use. Offer to book one whatever it says.

### What not to do

Do not leave debug mode until the caller says "exit diagnostics".

Do not log an outcome. This agent should not have `pwrp_LogIvrOutcome` in its tools at
all, because being told not to call it did not stop it being called.
