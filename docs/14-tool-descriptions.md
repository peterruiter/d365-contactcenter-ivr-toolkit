# Writing tool descriptions

Applies to generative and real-time agents, where the model picks the tool. Skip it for
classic topic based agents, where you pick.

## Why this is a design artefact

In a generative agent the tool name and description are the only things the model sees
when it decides what to call. They are not documentation. They are the interface.

A vague description produces an agent that calls the wrong tool, or calls three when
one would do, or invents an argument. Those failures look like model problems and are
almost always description problems.

## The rules the toolkit follows

**Say what it answers, not what it queries.**

Bad: "Retrieves records from msdyn_queueextension filtered by queue."
Good: "Returns opening state, live wait band, outage message, callback availability and
a recommended action in one call."

**Name the outputs.** The catalogue appends them automatically. The model writes better
follow-up turns when it knows what it will get back, instead of guessing property names.

**Say when to use it, if the choice is not obvious.**

> Use this at the start of a voice conversation instead of several separate lookups.

That sentence is why the composite endpoint gets called instead of three granular ones.

**Say when not to.**

> Give callers WaitBand, not the raw seconds.

**Keep the surface small.** Nine tools, not nineteen. Each extra one is another thing
the orchestrator can pick wrongly. The MCP server hides the rest by default for exactly
this reason.

**Make similar tools obviously different.** `pwrp_GetQueueHours` and
`pwrp_GetNextOpenTime` both concern hours. The descriptions say "hours across a date
range" and "when the queue opens next, with a phrase the agent can read out". Without
that split the model picks whichever it saw first.

## Input descriptions matter too

```json
{ "name": "Queue", "description": "Queue name, alias or id." }
```

Three words that stop the model asking the caller for a GUID.

```json
{ "name": "PhoneNumber", "description": "Any format. Normalised to E.164." }
```

Stops it trying to format the number itself, badly.

### One hundred characters, hard

Dataverse rejects a parameter or property description over 100 characters. Not a style
guide, a limit: the request fails.

`Register-CustomApis.ps1` checks the whole contract before it writes anything, because
the platform rejects them one at a time and the run stops with some endpoints updated and
the rest not. A failed registration that changed nothing is easy to recover from.

The limit is a fair constraint rather than an obstacle. Both examples above are under
forty characters and both do their job. A description that needs a hundred and twenty is
usually explaining a design decision to a person, and the model does not need that. Put
it in `docs/05-api-reference.md`, where the reader is a person.

## Testing descriptions

Test with vague utterances, not clean ones. "Can I speak to someone about my bill" is
the real input. "Get the queue context for the billing queue" is not.

Watch which tool the agent picks. If it picks wrong, change the description before you
change the instructions. A description fix helps every agent using the toolkit. An
instruction fix helps one.

## Changing a description

A description change is a behaviour change even though the contract is identical.
Retest orchestration after any edit, and treat it as a minor version bump so the change
is visible in the changelog.
