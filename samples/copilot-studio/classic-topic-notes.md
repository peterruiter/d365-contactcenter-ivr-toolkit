# Classic (topic based) agent wiring

The same Custom APIs, called deterministically. No orchestration risk, so the tool
descriptions matter less and the branching matters more.

## Topic: Opening hours

```
Trigger phrases: opening hours, are you open, what time do you close,
                 openingstijden, zijn jullie open, hoe laat sluiten jullie

Question    -> Which team do you need?           -> Var.QueueSpoken
Action      -> pwrp_GetQueueContext(Queue = Var.QueueSpoken)
Condition   -> Success = false
                 Condition -> ErrorCode = "QUEUE_AMBIGUOUS"
                                Message -> ErrorMessage, then loop back to the question
                 Otherwise -> Escalate
Condition   -> IsOpen = true
                 Message -> Speakable
               Otherwise
                 Action  -> pwrp_GetNextOpenTime(Queue = Var.QueueId)
                 Message -> Speakable
```

## Topic: Wait time

```
Action    -> pwrp_GetQueueMetrics(Queue = Var.QueueId)
Message   -> Speakable
```

Bind the message to `Speakable`, not to `LongestWaitSeconds`. The whole point of the
band is that the caller does not hear the raw number.

## Topic: Request a callback

```
Question  -> What number should we call?          -> Var.NumberSpoken
Action    -> pwrp_ValidatePhoneNumber(PhoneNumber = Var.NumberSpoken)
Condition -> IsValid = false
               Message -> Reason, loop back (max 2 retries, then escalate)
Message   -> Confirm: Speakable
Question  -> Is that correct?                     -> Var.Confirmed
Condition -> Var.Confirmed = yes
               Action  -> pwrp_CreateCallback(Queue = Var.QueueId,
                                              PhoneNumber = Var.E164,
                                              Mode = "Direct",
                                              ConversationId = System.Conversation.Id)
               Message -> Speakable
```

## Latency notes

- Hold `Var.QueueId` after the first resolve. Re-resolving a name on every turn adds
  a round trip you do not need.
- `pwrp_GetQueueContext` is one call. Three separate lookups is three.
- Watch `DurationMs` in the tool output during testing. If a call is consistently
  above your budget, check the metrics cache setting before you blame the platform.
