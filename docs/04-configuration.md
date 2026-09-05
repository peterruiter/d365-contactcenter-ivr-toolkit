# Configuration

Nothing client specific belongs in code. Everything here is data.

## Environment variables

| Schema name | Default | What it does |
|---|---|---|
| `pwrp_DefaultLocale` | `nl-NL` | Language for speakable output when a queue profile does not override it |
| `pwrp_DefaultTimeZone` | `W. Europe Standard Time` | Time zone for hours calculations |
| `pwrp_DefaultCountryCode` | `31` | Country calling code for phone normalisation, digits only |
| `pwrp_WaitBandThresholds` | `60,180,420` | Seconds. Short up to the first, Moderate to the second, Long to the third, VeryLong beyond |
| `pwrp_MetricsCacheSeconds` | `15` | How long live metrics are cached. Raise it on high volume queues |
| `pwrp_HoursCacheSeconds` | `300` | Hours and queue metadata cache. Safe to raise, hours rarely change |
| `pwrp_MetricsWindowMinutes` | `60` | Trailing window for the average wait calculation |
| `pwrp_EnableScheduledCallback` | `false` | Master switch. Off means only direct callback is offered |
| `pwrp_OutboundWorkstreamId` | empty | Required when scheduled callback is on |
| `pwrp_MaxCallbackAttempts` | `3` | Attempts before a callback is marked failed |
| `pwrp_CallbackRetryMinutes` | `20` | Gap between attempts |
| `pwrp_CallbackSlotMinutes` | `30` | Slot length for scheduled callback |
| `pwrp_TelemetryEnabled` | `true` | Duration tracing |

### Tuning the wait bands

The defaults suit a general service queue. Adjust to what the client's callers
actually tolerate, not to what the SLA says.

- Sales or retention queue: tighten to `30,90,240`. Patience is shorter.
- Technical support with known long handle times: `120,300,900`.
- Anything with a hard SLA: set the Moderate threshold at the SLA target so
  `OfferCallback` fires before you breach it.

## Queue profiles (`pwrp_queueprofile`)

One row per queue the IVR touches. The toolkit works without them and degrades
sensibly, but you lose the parts that make it sound human.

| Column | Purpose |
|---|---|
| `pwrp_queueid` | The queue this profile describes |
| `pwrp_speakablename` | How the agent says the queue name out loud |
| `pwrp_hourssource` | 1 = native operating hours, 2 = toolkit config tables |
| `pwrp_timezone` | Overrides the default. Set it on any queue outside the main region |
| `pwrp_locale` | Overrides the default. Set it on any queue serving another language |
| `pwrp_countrycode` | Overrides the default. Set it on any queue serving another country |
| `pwrp_directcallbackenabled` | Whether the agent may offer direct callback |
| `pwrp_scheduledcallbackenabled` | Whether the agent may offer a booked slot |
| `pwrp_slotcapacity` | Maximum callbacks per slot. Default 5 |

### Serving more than one country

Set `pwrp_countrycode` on every queue outside the main market, the same way you set
`pwrp_locale` and `pwrp_timezone`. It is the country calling code in digits, so `32` for
Belgium, `49` for Germany.

It only affects a number given in national format, but that is the dangerous case. A
Belgian caller saying "0475 123456" against the Dutch default becomes `+31475123456`,
which is a perfectly valid Dutch landline. No error, confirmed back digit by digit, and a
callback booked to a stranger.

### Speakable names matter more than you think

The queue is called `NL_CS_Tier1_Voice_PROD`. Nobody says that. Set the speakable
name to what a caller would recognise, and add the internal name as an alias so
supervisors can still use it in testing.

## Queue aliases (`pwrp_queuealias`)

Every way a caller might name a queue. Cheap to add, and the single highest return
configuration in the toolkit.

For a billing queue you would typically add: `facturatie`, `factuur`, `rekening`,
`betaling`, `billing`, `invoice`, plus the internal queue name.

Resolution order is exact alias, exact name, then fuzzy match above 78 percent
similarity. Two candidates within six points of each other return `QUEUE_AMBIGUOUS`
so the agent asks rather than guesses.

Watch the fuzzy matches in trace logs during testing. Every one of them is an alias
you should have configured.

## Hours

Pick a source per queue.

**Native operating hours** (`pwrp_hourssource = 1`) reads the calendar already maintained
in the admin centre. Right answer when hours are already there. Reads internal platform
schema, so it can break on a release wave.

The queue reaches its hours through a native lookup, so nothing needs configuring beyond
setting operating hours on the queue itself. Confirmed against a real environment on
2026-09-04:

| Step | How |
|---|---|
| Queue to operating hours | `queue.msdyn_operatinghourid`, a lookup |
| Operating hours to calendar | `msdyn_operatinghour.msdyn_calendarid`, a **string** holding a GUID, not a lookup |
| Calendar to opening windows | `ExpandCalendarRequest`, which is supported |

The rules are not parsed by the toolkit. `ExpandCalendarRequest` asks the platform to
expand them, and it returns concrete UTC blocks with the recurrence, the timezone and
daylight saving already applied. That matters because the rules are not readable in any
obvious way: the outer rule holds only the recurrence, the real times live on an inner
calendar as an offset in minutes from midnight, and `calendarrule` rejects a direct query
outright. Reading them by hand produced a queue that was open midnight to midnight.

The trade is latency. Expanding a calendar takes around 400ms against roughly 150ms for
reading rows, so a cold `GetQueueContext` sits near 450ms. Hours are cached for
`pwrp_HoursCacheSeconds`, so this is a first call cost rather than a per call one.

If a release wave moves any of this, switch the affected queues to config hours below and
fix `Hours/OperatingHoursProvider.cs`. Nothing else reads this model.

**Toolkit config** (`pwrp_hourssource = 2`) reads `pwrp_queuehours` and `pwrp_holiday`.
More setup, immune to schema drift, easy for a client admin to edit.

### `pwrp_queuehours`

One row per weekday window. Two rows for a lunch break.

| Queue | Day | Start | End |
|---|---|---|---|
| Billing | Monday | 08:30 | 12:00 |
| Billing | Monday | 13:00 | 17:30 |

### `pwrp_holiday`

Date overrides. Leave the queue empty to apply organisation wide.

| Name | Date | Queue | Start | End | Effect |
|---|---|---|---|---|---|
| Kerstmis | 25 Dec | (empty) | (empty) | (empty) | Everything closed |
| Oudjaarsdag | 31 Dec | (empty) | 09:00 | 13:00 | Short day everywhere |
| Team offsite | 14 Mar | Billing | (empty) | (empty) | Billing only closed |

A queue specific row beats an organisation wide one for the same date.

Load the national holidays for the next two years at install. Nobody remembers to do
it in December.

## Broadcast messages (`pwrp_broadcastmessage`)

An admin publishes one row when something is wrong. The agent reads it before
anything else, and `pwrp_GetQueueContext` returns `AnnounceOutage`.

| Column | Notes |
|---|---|
| `pwrp_message` | Read out word for word. Write it the way you want it spoken |
| `pwrp_queueid` | Leave empty for organisation wide |
| `pwrp_validfrom` / `pwrp_validto` | Always set an end. A stale outage message is worse than none |

Cached for 30 seconds, so a change reaches callers inside a minute.

## Message wording (`pwrp_messagetemplate`)

Overrides the built in phrases without a code change. One row per key per locale.
`Seed-Data.ps1` loads every key in `nl-NL` and `en-GB` with the built in wording, so the
whole vocabulary is visible in the app and nothing changes until a row is edited.

Change wording here, not in the agent instructions. Wording in one place stays consistent
across every topic.

A phrase is resolved most specific first: an override for the queue's locale, an override
for `en-GB`, the built in phrase for the locale, then the built in English. An unknown key
is ignored, so a typo silently does nothing rather than breaking a call.

### The keys, and what each may contain

A placeholder only works in the key that defines it. `{number}` in `open_now` stays
`{number}`, spoken literally to a caller.

| Key | Placeholders | Said when |
|---|---|---|
| `open_now` | `{close}` | The queue is open. `{close}` is the closing time |
| `closed_next` | `{next}` | Closed, and the next opening is known. `{next}` is a relative day and time |
| `closed_indefinite` | none | Closed with no next opening within the fortnight ahead |
| `holiday` | none | Closed for a holiday |
| `day_open` | `{day}`, `{windows}` | One line of a multi day answer. `{windows}` is the times, joined by `and` |
| `day_closed` | `{day}` | One line of a multi day answer, for a closed day |
| `wait_short` | none | Wait is inside the first threshold |
| `wait_moderate` | none | Wait is past the first threshold |
| `wait_long` | none | Wait is past the second |
| `wait_verylong` | none | Wait is past the third |
| `callback_booked` | `{when}`, `{number}` | A scheduled callback is booked |
| `callback_queued` | `{number}` | A direct callback is queued |
| `today` | none | Word for a time later today. Used inside `{next}` and `{when}` |
| `tomorrow` | none | Word for a time tomorrow |
| `at` | none | Joins a day and a time, as in "tomorrow at 09:00" |
| `and` | none | Joins two opening windows on one day |

The last four are fragments rather than sentences. They are overridable because a language
that joins words differently cannot be fixed by editing the sentences alone.

### Wording is per locale, and the locale comes from the queue

Set `pwrp_locale` on the queue profile. An agent serving English callers from a queue left
at `nl-NL` gets Dutch phrases, whatever the agent's own language is. `en-GB` and `nl-NL`
are built in; another locale needs a full set of rows, and falls back to English until it
has them.
