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

### "is missing prvReadPluginType privilege" or prvReadPluginAssembly

The caller is an application user whose security role is short of two privileges. Nothing
in the toolkit queries either table. The platform reads them when it resolves a Custom API
to the code behind it, so without them no endpoint runs at all.

Add `plugintype` and `pluginassembly` read to the role. They are in `build/schema.json`,
so re-running `New-SecurityRole.ps1` is enough.

The confusing part is that only some endpoints fail. Whichever call warms the metadata
cache first succeeds and the rest do not, so the failure moves between runs. Nothing is
special about the ones that pass.

You will only ever see this as an application user. As an administrator everything works,
which is why `Test-Endpoints.ps1` takes client credentials.

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

### Hours are wrong, or the queue looks open around the clock

Opening times come from `ExpandCalendarRequest` rather than from reading calendar rules,
so the platform applies the recurrence, the timezone and daylight saving. If the answer is
wrong, the calendar is wrong, and the admin centre will show the same wrong hours.

A queue reported as open midnight to midnight means the calendar's outer rule is being
read instead of the inner one. That was a real defect, fixed on 2026-09-04. If it comes
back after a release wave, switch the affected queues to config hours and raise it.

Do not trust the operating hours record's name. One seen in testing was called
"Mon-Fri 09:00-17:00" while its rule said all seven days from 08:00, and the toolkit
correctly reported what the rule said.

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

Run `pwrp_HealthCheck` first. **Callback promotion** failing means records are going
overdue, which narrows this to steps 1 to 4.

Work through in order:

1. The promotion flow exists. Before 3.4.0 it was documented but never shipped, so an
   environment installed before then has nothing promoting anything. Run
   `build/New-PromotionFlow.ps1`
2. Its connection reference is bound to a connection, and the flow is switched on. It is
   created switched off on purpose
3. `pwrp_EnableScheduledCallback` is true
4. `pwrp_OutboundWorkstreamId` points at a real outbound workstream. The flow throws
   `pwrp_OutboundWorkstreamId is not set` rather than promoting
5. Records are moving from `Requested` to `Queued`
6. Proactive engagement is configured in preview dial mode
7. Representatives are in the outbound capacity profile

If records reach `Queued` and still nobody is called, it is 6 or 7, and 7 is the usual one.

### `Failed to retrieve dynamic inputs` on the promotion flow action

```
Failed to retrieve dynamic inputs. Error details: 'Request to XRM API failed with
error: 'Message: Code: InnerError: '.'
```

The connection is fine. The designer is asking Dataverse to describe
`pwrp_PromoteDueCallbacks` so it can draw its parameters, and Dataverse will not.

Before 3.4.1 that API was registered with the platform's `isprivate` flag set. A private
message is deliberately hidden from the metadata connectors read, so the Dataverse
connector cannot describe it and cannot call it either. The flow was calling something it
was not allowed to see.

There are two rows, which is why clearing the flag once may not be enough. Creating a
custom API generates an `sdkmessage` row, and that row is what the connector reads. It
holds its own copy of `isprivate` and it cannot be edited: Dataverse refuses `Update` on
the `sdkmessage` table. Replacing the API is the only way to get a new message.

Ignore `isactive` on these messages. It reads false on every custom API here, working ones
included.

Re-register against the current contract, then check what the platform now says:

```powershell
pwsh build/Register-CustomApis.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
pwsh build/Get-ApiRegistration.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
```

`Get-ApiRegistration.ps1` is read only. It reports the `customapi` row and the
`sdkmessage` row that was generated from it, because the connector reads the message and
the two hold separate copies of `isprivate`.

If it reports `sdkmessage.isprivate is true`, replace the API so it gets a new message:

```powershell
pwsh build/Register-CustomApis.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com -Recreate pwrp_PromoteDueCallbacks
```

If it reports every API visible and the action is still missing from the designer's
picklist, the remaining explanation is the connector's own cache. It caches the message
list per connection, and a message that did not exist when the connection was made stays
missing. Create a new Dataverse connection, point the **Power Pete Dataverse** connection
reference at it, and reopen the flow.

Nothing in the flow itself needs changing in any of these cases.

### The promotion flow shows errors the moment you open it

Two banners, both expected on a flow that has just been created:

```
Some of the connections are not authorized yet.
Request to XRM API failed with error: 'Message: Code: InnerError: '
```

The second is caused by the first. The designer resolves the parameters of
`pwrp_PromoteDueCallbacks` by asking Dataverse through the connection, and the connection
reference is not bound to one yet, so that lookup fails and reports nothing useful.

**Do not press Save while the first banner is up.** The designer treats an unauthorized
connection as one to rewrite, and saving replaces the connection reference the script put
in with whatever it can resolve, which is usually nothing.

Bind it instead, then reopen:

1. Solutions > Power Pete Contact Center IVR Toolkit > Connection references
2. Open **Power Pete Dataverse** and pick a Dataverse connection, or create one
3. Reopen the flow. Both banners should be gone

The account behind that connection needs the toolkit security role. It is the identity that
calls `pwrp_PromoteDueCallbacks`, not the caller and not you.

### A response property is listed two or more times

Re-run `build/Register-CustomApis.ps1`. It prints a yellow `- removed duplicate` line for
each one it deletes.

Before 3.4.0 the registration matched existing children on the two uniquename spellings
that script had used. A row written under any other convention was invisible to it, so it
survived every run while a new one was created alongside. The `ccit_` prefixed rows from
before the rebrand are the common source. They share a `name` with the row that is wanted,
so the maker portal lists the property twice, or four times, and the API returns whichever
row Dataverse picks.

### Phone numbers rejected that look fine

`pwrp_ValidatePhoneNumber` returns a `Reason`. Read it. Common cases:

- Dutch number without the leading zero and without a country code. Set
  `pwrp_DefaultCountryCode` correctly
- Non-Dutch number where only a length check applies. Valid but typed `Unknown`
- Speech gave nine digits instead of ten. Ask again rather than guessing

### `E164` comes back with a dash or other rubbish in it, like `+-653740141`

The plugin assembly is older than 3.4.0. A `CountryCode` that cannot be one, the `-`
placeholder the tool tables tell you to type among them, was concatenated onto the number
and the result passed the length check. Deploy the current assembly.

`IsValid` came back true for those numbers, so nothing downstream caught it. If callbacks
were booked while it was happening, check `pwrp_callbackrequest` for numbers that are not
in the queue's country.

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
