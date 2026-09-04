# Troubleshooting

## Install

### Solution import fails on plugin registration

The assembly is not strong named, or the signing key changed between builds. Rebuild
with `./build/build.ps1`. If you regenerated the key, the import is treated as a
different assembly and you need to remove the old one first.

### Register-CustomApis.ps1 fails with 403

The account is not System Administrator. Custom API metadata needs it. A regular
System Customizer cannot register plugin types.

### Health check: "Queues discovered - 0 active queues found"

Unified routing is not provisioned, or the account has no read access to queues. Check
prerequisites before you look at the toolkit.

### Health check: "Metrics schema - failed"

`msdyn_queueextension` is not readable. Either Contact Center is not fully
provisioned, or a release wave has moved the table. See
[ALM and support](10-alm-and-support.md).

## Runtime

### `QUEUE_NOT_FOUND` on a name that obviously matches

Check the queue is active. The resolver only returns active queues.

Then check the cache. Queue metadata is cached for `pwrp_HoursCacheSeconds`, so a
queue created two minutes ago may not be visible yet. Wait, or lower the TTL while
testing.

### `QUEUE_AMBIGUOUS` too often

Two queues have overlapping aliases. Look at the candidates in `ErrorMessage` and
remove the alias they share. Adding a distinctive alias to each also works and is
usually better.

### Fuzzy matching picks the wrong queue

The 78 percent floor is deliberately permissive because speech output is messy. If a
specific pair keeps colliding, add exact aliases for both. Exact match always beats
fuzzy.

### `HOURS_NOT_CONFIGURED`

No operating hours are linked to the queue, and the profile is set to native hours.
Either link hours in the admin centre, or switch `pwrp_hourssource` to 2 and populate
`pwrp_queuehours`.

### Hours are an hour out

Time zone. Check `pwrp_timezone` on the queue profile, then `pwrp_DefaultTimeZone`.
The toolkit converts UTC to the queue time zone, so a queue in another region needs
its own value.

If it is out by exactly an hour only part of the year, someone has hardcoded an offset
somewhere instead of using a time zone id.

### `METRICS_UNAVAILABLE`

Expected during a platform update, and the agent should carry on without mentioning
wait times. If it persists, run the health check. A failing metrics schema check means
the internal tables have moved.

### Metrics look wrong

| Symptom | Likely cause |
|---|---|
| `WaitingNow` always 0 | The queue has no live segments, or the queue filter is matching nothing. Verify with the real-time dashboard |
| `AverageWaitSeconds` 0 with traffic | No conversations accepted inside `pwrp_MetricsWindowMinutes`. Widen the window on a low volume queue |
| `RepresentativesAvailable` 0 with people signed in | They are signed in but not Available, or not members of this queue |
| Numbers lag behind the dashboard | Cache. `pwrp_MetricsCacheSeconds` defaults to 15 |

### `RepresentativesOnline` high but nobody answers

That is the point of having both numbers. Online counts anyone signed in. Available
counts those in an Available presence. Use Available.

### Callback returns an existing request instead of creating one

Working as designed. A callback is already open for that queue and number.
`pwrp_GetCallbackStatus` shows it. Cancel the existing one to book a different time,
or use reschedule.

### `CALLBACK_SLOT_UNAVAILABLE` on a slot the agent just offered

Someone booked it in between. Slots are checked at creation, not reserved when
offered. Re-fetch and offer again. Frequent collisions mean `pwrp_slotcapacity` is
too low for the volume.

### Scheduled callbacks never get dialled

Work through in order:

1. `pwrp_EnableScheduledCallback` is true
2. `pwrp_OutboundWorkstreamId` points at a real outbound workstream
3. The promotion flow is turned on and running
4. Records are moving from `Requested` to `Queued`
5. Proactive engagement is configured in preview dial mode
6. Representatives are in the outbound capacity profile

Step 6 is the usual one.

### Phone numbers rejected that look fine

`pwrp_ValidatePhoneNumber` returns a `Reason`. Read it. Common cases:

- Dutch number without the leading zero and without a country code. Set
  `pwrp_DefaultCountryCode` correctly
- Non-Dutch number where only a length check applies. Valid but typed `Unknown`
- Speech gave nine digits instead of ten. Ask again rather than guessing

## Latency

### Calls feel slow

Check `DurationMs` first. If it is low, the delay is not in the toolkit.

| Cause | Fix |
|---|---|
| Several tool calls per turn | Use `pwrp_GetQueueContext` |
| Dynamic greeting | Make the greeting static |
| Re-resolving the queue every turn | Hold `QueueId` in a variable |
| Metrics query on a busy queue | Raise `pwrp_MetricsCacheSeconds` |
| Too many tools registered | Remove the ones the agent does not need |

### First call after a quiet period is slow

Plugin sandbox cold start plus an empty cache. Normal. If it matters, a keep warm
flow calling `pwrp_HealthCheck` every few minutes helps.

## Getting help

Include the plugin trace log, the `ErrorCode`, the toolkit version and the output of
`Test-Installation.ps1`. Without those the first reply will just ask for them.
