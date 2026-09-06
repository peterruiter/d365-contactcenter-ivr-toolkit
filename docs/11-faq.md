# FAQ

**Do I need Azure?**
No. Everything runs as Dataverse plugins inside the managed solution.

**Does this work with Customer Service, or only Contact Center?**
Both, provided unified routing and the voice channel are provisioned. The tables are
the same.

**Which endpoint should my agent call first?**
`pwrp_GetQueueContext`. In most voice scenarios it is the only one you need before
speaking.

**Why does it return both raw seconds and a band?**
The seconds are for supervisors, reporting and tuning your thresholds. The band is for
callers. Reading a number of waiting callers out loud makes people hang up.

**Can I get position in queue?**
`WaitingNow` gives you queue depth. Position for a specific caller needs the
conversation id and is not exposed, because a voice agent that has not yet been
transferred does not have a work item in the queue to report a position for.

**Why does queue resolution use fuzzy matching?**
Because speech recognition produces "klanten service" and "rekening spul". Exact
matching would fail on most real calls. The ambiguity error stops it guessing when it
should ask.

**Can I turn fuzzy matching off?**
Add exact aliases for everything and the exact path always wins before fuzzy is
attempted. There is no switch, because a hard failure on a slightly misheard name is
a worse caller experience.

**Which hours source should I pick?**
Native operating hours if the client already maintains them there. Toolkit config
tables if they do not, or if you want insulation from platform schema changes. It is
a per queue setting, so you can mix.

**Do I have to build scheduled callback?**
No. Direct callback is native and covers most requirements. Only build scheduled
callback if the client specifically needs the caller to pick a time.

**Does customer-first direct callback make this redundant?**
No, and where it fits you should use it: it rings the customer before reserving a
representative, which is better than anything the toolkit would build. It is an overflow
action, so the caller is already in a queue and the request keeps its place until it
reaches the front. The caller never chooses a time and cannot reschedule or cancel.
Scheduled callback here starts wherever the agent decides, including out of hours, offers
slots, and can be moved or cancelled by reference. Different question, so run both. See
the [overview](01-overview.md).

**Does the toolkit place calls?**
No. Proactive engagement in preview dial mode does. The toolkit writes the request
and a flow hands it over.

**What happens if the metrics read fails during a call?**
`pwrp_GetQueueContext` still returns, with the wait band defaulted to Moderate. The
agent continues without mentioning wait times. It never tells a caller a system is down.

**How many languages does it speak?**
nl-NL and en-GB out of the box. Others fall back to en-GB. Add entries to
`pwrp_messagetemplate` to extend, or add a resource block for a new locale.

**Can two clients run different versions?**
Yes, and they usually will. The Custom API contract is stable within a major version,
so agents keep working across minor upgrades.

**How do I know if the agent is actually containing calls?**
`pwrp_ivroutcome`. If the rows are missing, the agent is not calling
`pwrp_LogIvrOutcome` on every path. That is the most commonly missed wiring step.

**How much latency does this add?**
150 to 400 ms for a context call in a healthy environment. Watch `DurationMs`. If it
is low and calls still feel slow, the delay is elsewhere in the agent.

**Is this supported by Microsoft?**
No. It is an open source Power Pete toolkit built on the Dataverse platform. The queue,
hours and callback paths use supported schema. The live metrics path reads internal
tables and is explicitly at your own risk. See [ALM and support](10-alm-and-support.md).
