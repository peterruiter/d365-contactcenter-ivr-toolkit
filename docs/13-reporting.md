# Reporting

Two questions the client will ask after go live. Have the answers ready.

## Containment

`pwrp_ivroutcome`, one row per conversation.

```
Containment = Contained / all outcomes
Deflection  = (Contained + CallbackBooked + ClosedAnnouncement) / all outcomes
```

Containment is the strict number: the agent resolved it, no person involved.
Deflection is the honest one for a business case, because a booked callback and a
closed announcement both saved a queued call.

FetchXML for a weekly breakdown:

```xml
<fetch aggregate="true">
  <entity name="pwrp_ivroutcome">
    <attribute name="pwrp_ivroutcomeid" alias="volume" aggregate="count" />
    <attribute name="pwrp_outcome" alias="outcome" groupby="true" />
    <attribute name="pwrp_occurredon" alias="week" groupby="true" dategrouping="week" />
    <filter>
      <condition attribute="pwrp_occurredon" operator="last-x-weeks" value="12" />
    </filter>
  </entity>
</fetch>
```

If outcome rows are missing, the agent is not calling `pwrp_LogIvrOutcome` on every
path. That is the most commonly missed wiring step, and it is usually the closed and
abandoned paths that get forgotten.

## Callback performance

```
Uptake        = CallbackBooked / conversations that hit a Long or VeryLong band
First attempt = Completed with attempts = 1 / all Completed
Failure rate  = Failed / (Completed + Failed)
```

First attempt success is the number that tells you whether your slot model works. Below
about 70 percent means slots are too wide, capacity is too high, or the retry gap is
too short for people to get back to their phone.

```xml
<fetch aggregate="true">
  <entity name="pwrp_callbackrequest">
    <attribute name="pwrp_callbackrequestid" alias="volume" aggregate="count" />
    <attribute name="pwrp_attempts" alias="attempts" aggregate="avg" />
    <attribute name="pwrp_status" alias="status" groupby="true" />
    <attribute name="pwrp_mode" alias="mode" groupby="true" />
    <filter>
      <condition attribute="createdon" operator="last-x-days" value="30" />
    </filter>
  </entity>
</fetch>
```

## Resolution quality

The queue text column on `pwrp_ivroutcome` is populated only when the spoken queue
could not be resolved. Every distinct value is a missing alias.

```xml
<fetch aggregate="true">
  <entity name="pwrp_ivroutcome">
    <attribute name="pwrp_ivroutcomeid" alias="volume" aggregate="count" />
    <attribute name="pwrp_queuetext" alias="spoken" groupby="true" />
    <filter>
      <condition attribute="pwrp_queuetext" operator="not-null" />
      <condition attribute="pwrp_occurredon" operator="last-x-days" value="30" />
    </filter>
  </entity>
</fetch>
```

Sort descending and work down the list. The first ten aliases you add from this query
will do more for containment than any prompt tuning.

## Wait band accuracy

Worth checking quarterly. If callers abandon at the same rate whether you said Short or
Long, the bands are not telling them anything useful.

Join `pwrp_ivroutcome` on conversation id to the conversation records, group by the
band the agent announced, and compare abandonment rates. A healthy split shows
abandonment climbing across the bands. A flat line means retune
`pwrp_WaitBandThresholds`.

## Power BI

The two toolkit tables are small and query well through the Dataverse connector.

Do not rebuild the real-time dashboards. Supervisors have those, they are better, and
they are supported. This is for the IVR layer only: what did the agent do, and did it
work.

A useful single page:

- Containment and deflection trend, weekly
- Outcome mix, stacked
- Top unresolved queue names, descending, as a work list
- Callback uptake and first attempt success
- Announced wait band against actual abandonment

## Retention

`pwrp_ivroutcome` grows one row per call. On a contact centre taking 5,000 calls a day
that is 1.8 million rows a year.

Agree a retention policy at go live. Twelve months of detail with a monthly aggregate
kept beyond that suits most clients. Use the Dataverse long term retention feature
rather than a delete job, so the history stays queryable.
