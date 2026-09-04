# Operations

What to do once it is live.

## Publishing an outage message

An admin creates a `pwrp_broadcastmessage` row. The agent reads it before anything
else, and `pwrp_GetQueueContext` returns `AnnounceOutage`.

1. Open the Contact Center IVR Toolkit app > Broadcast messages > New
2. Write the message the way you want it spoken, not the way you would write it
3. Set the queue, or leave it empty for organisation wide
4. Always set `pwrp_validto`

Reaches callers inside a minute. A stale outage message is worse than no message, so
the end date is not optional.

## Monitoring

### Latency

`DurationMs` comes back on every response. Log it in the agent and alert on the 95th
percentile.

Rough shape of a healthy call:

| Endpoint | Typical | Investigate above |
|---|---|---|
| `pwrp_GetQueueContext` | 150 to 400 ms | 800 ms |
| `pwrp_GetQueueMetrics` | 100 to 300 ms | 600 ms |
| `pwrp_GetQueueHours` | 50 to 150 ms cached | 400 ms |
| `pwrp_CreateCallback` | 200 to 500 ms | 900 ms |

A slow `GetQueueContext` is usually the metrics query on a busy queue. Raise
`pwrp_MetricsCacheSeconds` before you look anywhere else.

### Containment

`pwrp_ivroutcome` is the source. One row per conversation.

```
Containment rate  = Contained / all outcomes
Deflection rate   = (Contained + CallbackBooked + ClosedAnnouncement) / all outcomes
```

If outcome rows are missing, the agent is not calling `pwrp_LogIvrOutcome` at the end
of every path. That is the most commonly missed wiring step.

### Resolution quality

Watch the plugin trace log for fuzzy match lines:

```
[pwrp] fuzzy matched 'rekening spul' to 'Billing NL' at 81
```

Every one is an alias you should add. Review weekly for the first month, then monthly.

`QUEUE_AMBIGUOUS` frequency is the other signal. Rising means two queues have
overlapping aliases and callers are being asked an extra question they should not need.

## After a release wave update

Contact Center release waves land twice a year. The metrics reader depends on internal
platform tables.

```powershell
./build/Test-Installation.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
```

Run it in the client's sandbox before the production wave lands. If the metrics check
fails, see [ALM and support](10-alm-and-support.md).

## Routine maintenance

| Task | Frequency |
|---|---|
| Load next year's holidays | Annually, before December |
| Review fuzzy matches and add aliases | Weekly for a month, then monthly |
| Review wait band thresholds against actual abandonment | Quarterly |
| Health check | After every solution or platform update |
| Archive old `pwrp_ivroutcome` rows | Per the client's retention policy |
| Review slot capacity against actual callback load | Monthly for the first quarter |

## Turning things off in a hurry

| Situation | Action |
|---|---|
| Metrics returning nonsense | Raise `pwrp_MetricsCacheSeconds` to 3600, then investigate |
| Callback overloading a queue | Set `pwrp_scheduledcallbackenabled = false` on the profile |
| All callbacks need stopping | Set `pwrp_EnableScheduledCallback = false` |
| Wrong queue being matched | Remove the offending alias. Takes effect within the hours cache TTL |

None of these need a deployment. That is deliberate.
