# Changelog

Semantic versioning. The Custom API contract is stable within a major version.

| Change | Bump |
|---|---|
| New endpoint, optional input, or output property | Minor |
| Description change (behaviour change in a generative agent) | Minor |
| Internal fix, same contract | Patch |
| Removed or renamed output, changed enum, changed meaning | Major |

## [1.0.0]

First release. Published as an open source Power Pete project under the MIT licence.
Publisher prefix `pwrp`, namespace `PowerPete.IvrToolkit`.

### Endpoints

Seventeen public, two private.

- Queues: `GetQueues`, `ResolveQueue`, `GetQueueContext`
- Hours: `GetQueueHours`, `IsQueueOpen`, `GetNextOpenTime`
- Live state: `GetQueueMetrics`
- Callback: `CheckCallbackEligibility`, `GetCallbackSlots`, `CreateCallback`,
  `GetCallbackStatus`, `CancelCallback`, `RescheduleCallback`
- Utility: `ValidatePhoneNumber`, `GetBroadcastMessage`, `LogIvrOutcome`, `HealthCheck`
- Private, for flows: `PromoteDueCallbacks`, `RecordCallbackOutcome`

### Capabilities

- Queue resolution by name, alias and fuzzy match, with an explicit ambiguity error so
  an agent asks instead of guessing
- Opening hours from either the native operating hours calendar or the toolkit's own
  config tables, switchable per queue
- Holiday exceptions, organisation wide or per queue
- Live queue metrics: callers waiting, longest wait, trailing average, representatives
  available, estimated wait, wait band
- Composite `GetQueueContext` returning a single recommended action
- Direct callback eligibility and status over the native platform feature
- Scheduled callback with slot capacity, deduplication, retry policy, expiry, cancel and
  reschedule, dispatched through proactive engagement
- Phone number normalisation to E.164 with Dutch mobile and landline detection
- Broadcast messages for outages
- IVR outcome logging for containment reporting
- Speakable output in nl-NL and en-GB, overridable without a code change

### Tooling

- Guided six step installer, prerequisite checker, health check
- Schema provisioning from `schema.json`, and solution export helper
- Dutch public holiday seeding with movable feast calculation
- Custom API registration from `customapis.json`, upsert based so reruns preserve agent
  bindings
- Connector swagger generated from the same contract file
- Optional MCP server with a catalogue generated from that contract, plus Bicep for a
  Container App
- Azure DevOps pipeline with solution checker, generated artefact drift check, and a
  health check gate in a test environment

### Documentation

Fourteen documents covering overview, prerequisites, installation, configuration, API
reference, Copilot Studio wiring, scheduled callback, operations, troubleshooting, ALM
and support, FAQ, MCP server, reporting, and writing tool descriptions.

### Known limits

- Live metrics read `msdyn_queueextension` and `msdyn_agentstatushistory`, internal to
  the platform and carrying no API guarantee. Run the health check after every release
  wave update. The toolkit degrades rather than fails when they change.
- `OperatingHoursProvider` reads the native calendar model, which is also internal.
  Switch affected queues to config hours if a wave breaks it.
- Scheduled callback needs proactive engagement and an outbound workstream. The toolkit
  does not place calls.
- Speakable output covers nl-NL and en-GB. Others fall back to en-GB.
- Queue position for an individual caller is not exposed. A voice agent that has not yet
  transferred has no work item in the queue to report a position for.
- The solution folder ships empty apart from the promotion flow. Bootstrap a development
  environment with `New-Schema.ps1`, then export and commit.
