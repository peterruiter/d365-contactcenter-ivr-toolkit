# Changelog

Semantic versioning. The Custom API contract is stable within a major version.

| Change | Bump |
|---|---|
| New endpoint, optional input, or output property | Minor |
| Description change (behaviour change in a generative agent) | Minor |
| Internal fix, same contract | Patch |
| Removed or renamed output, changed enum, changed meaning | Major |

## [3.3.0]

### Fixed

- A country code that cannot be one is ignored instead of being used as the dialling
  prefix. A tool configuration cannot leave an optional input out, so makers type a
  placeholder, and the documented placeholder `-` was concatenated straight onto the
  number: a caller who said `0653740141` got `+-653740141` back, reported valid, and that
  is what was written to the callback. `docs/06-copilot-studio.md` had claimed for two
  versions that a non-digit value was ignored. It is now true
- `pwrp_ValidatePhoneNumber` falls through to the queue's country when the `CountryCode`
  input is a placeholder, which is the resolution order the documentation always described
- A last check that a valid number really did normalise to digits. It cannot fail given
  the fix above, which is the point: the previous version had no such check and shipped a
  number with a dash in it

### Changed

- The `PhoneNumber` input description for `pwrp_CreateCallback` said to send the `E164`
  that validation returned. The agent instructions said to send the number as the caller
  said it and never to rebuild it. Both were in the product, they contradict each other,
  and the tool description is the one a model reads at call time. It now matches the
  instructions: send what the caller said, and let the toolkit normalise once using the
  queue's country
- The agent no longer reads the callback reference out for a direct callback. Six
  characters mean nothing to someone who has just been told they will be rung back
  shortly, cannot be written down in a car, and make a simple answer sound like a case
  number. It is read when the caller asks, when the callback is for a booked time, or
  when they need to quote it back
- An agent with no `pwrp_GetCallbackSlots` tool now says scheduled callback is not
  offered, rather than that it could not retrieve the slots. The second sounds like an
  outage and leaves the caller waiting for a fix that is not coming

## [3.2.0]

### Added

- A **Settings** page in the model driven app, `src/webresources/pwrp_settings.html`.
  There was no way to reach a setting from the app at all: an administrator had to know
  that a setting is an environment variable, that environment variables live under the
  solution, and where the solution is
- Guidance on every one of the thirteen settings. None of them had a description, in the
  environment or anywhere else, so `New-Schema.ps1` now writes one from `schema.json` and
  refreshes it on a rerun. The page displays it under each field. The text says what the
  setting does and what goes wrong when it is set badly, including the pairing that
  catches everyone: `pwrp_EnableScheduledCallback` and the queue profile flag are both
  required, so turning one on alone appears to do nothing
- The shipped default on every setting, whether or not it has been overridden. It was
  only in the faint schema line, and absent entirely when the default was empty, so a
  setting that had been changed gave no way to see what it used to be
- **Use default** on each setting, which deletes the value row. Clearing the box and
  saving never did this. An empty string is a value, and the platform refuses one on some
  types, so there was no way back to a default short of deleting the record by hand
- **Run health check** on the page, calling `pwrp_HealthCheck` and listing each check
- `pwrp_OutboundWorkstreamId` is a dropdown of the environment's active outbound
  workstreams, by name, rather than a box to transcribe a GUID into. A configured
  workstream that has since been deactivated is kept as an option, because a dropdown
  silently dropping a value it has no option for would turn saving into clearing
- A live worked example under `pwrp_WaitBandThresholds`, turning the three numbers into
  the four bands a caller lands in, and saying so when they do not rise
- An app tile icon, `build/assets/app-icon.svg`, uploaded as a solution web resource. The
  app previously showed the platform default tile, shared with several other apps in the
  selector

### Fixed

- `New-Schema.ps1` treated any failure creating an environment variable definition as
  proof that one already existed. A transient platform error was swallowed and the script
  then tried to patch a definition that had never been created. Existence is now looked up
- `New-Schema.ps1` retried only the metadata cache race. It now also retries the platform
  dropping the connection while somebody else's schema customisation runs, which is
  transient and can land on any call
- `Invoke-Dataverse` retries solution contention, so a run no longer dies at step forty
  because someone started an import. A publish is refused outright while another import
  is running, and refused means nothing was applied, which is what makes the retry safe.
  When the retries run out the message says to check Solution History rather than leaving
  the platform's wording to be read as a bug in the toolkit

## [3.1.0]

### Fixed

- `pwrp_messagetemplate` is read. The table was created, seeded, put on the app and
  documented as the way to change wording without a deployment, and nothing in the plugin
  ever looked at it. Every override silently did nothing

A phrase now resolves most specific first: an override for the queue's locale, an override
for `en-GB`, the built in phrase for the locale, then the built in English. Overrides are
cached for `pwrp_HoursCacheSeconds`.

### Added

- `Seed-Data.ps1` loads all sixteen keys in both `nl-NL` and `en-GB`, matching the built in
  wording, so the vocabulary is visible in the app instead of existing only in source. It
  skips rows that already exist, so a reseed never overwrites edited wording
- The keys and the placeholders each one accepts are documented in
  `docs/04-configuration.md`. They were not written down anywhere

## [3.0.0]

### Changed, and it breaks callers

- `pwrp_GetQueueContext` returns `BroadcastMessage` as an output, and no longer returns
  `AnnounceOutage` as a `RecommendedAction`

An announcement was being treated as an action. A queue with an outage notice returned
`AnnounceOutage` and a `Speakable` containing the notice, which threw away the wait band
that had just been calculated. A caller heard "we are busy" and was never told how long
or offered anything. Read `BroadcastMessage` first, then act on `RecommendedAction`.

- A callback is offered whenever the wait is not `Short`, rather than only at `Long` and
  `VeryLong`. The threshold lives in `pwrp_WaitBandThresholds`, which is where it belongs

### Fixed

- `pwrp_ValidatePhoneNumber` spells the number back in the format the caller used. It
  spelled the stored E.164, so someone who said "0653740141" heard "3 1 6 5 3 7 4 0 1 4 1"
  and could not tell whether a digit had been missed

Seen in a real call: the agent read nine of the eleven digits, rebuilt the number from
what it had read, and sent `+653740141` to `pwrp_CreateCallback`. That is a valid looking
Singapore number, so it was stored and would have been dialled. The sample instructions
now say to send the caller's own words to both endpoints and never to rebuild a number.

## [2.1.0]

### Added

- `pwrp_queueprofile.pwrp_countrycode`, next to the locale and timezone overrides that
  were already there. Set it on any queue serving another country
- `pwrp_ValidatePhoneNumber` takes an optional `Queue`. Country resolves most specific
  first: an explicit `CountryCode`, then the queue, then `pwrp_DefaultCountryCode`

### Fixed

- `pwrp_CreateCallback` validated the number against the organisation default while
  holding the queue that knew better. A Belgian caller booking through a Belgian queue
  had their number stored as Dutch

Only numbers given in national format were affected, and they failed silently rather than
erroring: `0475 123456` read against the Dutch code is `+31475123456`, nine digits after a
valid country code, so it came back as a valid Dutch landline and was confirmed to the
caller digit by digit.

`pwrp_GetCallbackStatus` still uses the organisation default on purpose. A caller looking
up a callback gives a number and nothing else, and a lookup that misses is harmless where
a booking against the wrong number is not.

Run `New-Schema.ps1` and then `Update-Forms.ps1` to pick up the new column.

## [2.0.0]

### Changed, and it breaks callers

- Every endpoint is now an action. The thirteen read endpoints were functions, called as
  `GET pwrp_GetQueueContext(Queue='HR')`, and are now `POST pwrp_GetQueueContext` with a
  JSON body. Anything calling them directly has to change

Copilot Studio's Dataverse connector offers only actions under **Perform an unbound
action**. Declaring the reads as functions was semantically right and left thirteen
endpoints, `pwrp_GetQueueContext` among them, unreachable from the integration route the
README calls the default. Found by wiring up an agent, which is the only way it shows.

Changing this on an existing environment replaces the affected Custom APIs, because
whether an API is a function is fixed once it exists. `Register-CustomApis.ps1` detects
the change, deletes and recreates them, and reports each one. Their parameters and
response properties go with them, so anything bound to an old definition needs rebinding.

## [1.1.0]

### Added

- `pwrp_GetQueueContext` returns `DirectCallbackAvailable` and `ScheduledCallbackAvailable`
  as outputs. They were already computed and sat inside the `Context` payload, where an
  agent could only reach them by parsing a string, so offering a callback cost a second
  call to `pwrp_CheckCallbackEligibility` on the most latency sensitive path in the toolkit
- `pwrp_CreateCallback` returns `IsExisting`, true when a request already existed and was
  returned rather than created. Deduplication was deliberate but invisible, so an agent
  could not tell a repeat from a fresh booking

Both are additive. An agent built against 1.0.x keeps working.

## [1.0.4]

First release verified against a live Dynamics 365 Contact Center environment. Every
change below came from running the toolkit rather than reviewing it.

### Fixed

- `msdyn_queueextension` links queues through `msdyn_queueid`. There is no `msdyn_queue`
- The conversation join is `msdyn_conversationid` to `activityid`. `msdyn_ocliveworkitem`
  is an activity table, so its key is not `msdyn_ocliveworkitemid`
- Available presence is `192360000`. It was `192350000`, which never threw and simply
  counted every representative as unavailable
- Optional `DateTime` inputs arrive as `default(DateTime)` rather than absent, so a null
  coalescing default never fired and hours were answered for the year 1
- Opening hours are expanded by `ExpandCalendarRequest` instead of by reading calendar
  rules. The rules are two levels deep and were being read one level up, which reported
  every queue as open around the clock
- The security role was missing read on `plugintype` and `pluginassembly`, without which
  no Custom API runs for an application user
- Custom API parameter `uniquename` must be the bare name. It is the property name in the
  generated message
- The plugin assembly is merged without the SDK and keeps its strong name

### Added

- The model driven app and its sitemap, created by `New-ModelDrivenApp.ps1`
- Forms and views generated from `schema.json` by `Update-Forms.ps1`
- `New-ApplicationUser.ps1`, and endpoint tests that run as the application user
- `New-SecurityRole.ps1`, which resolves privilege ids from metadata at run time
- `Import-PluginAssembly.ps1`, `Test-Endpoints.ps1`, `Test-WritePaths.ps1`, `New-DemoData.ps1`

### Changed

- Every environment script talks to the Web API directly. `pac env http`, which they were
  written against, is not a command in any published CLI version
- The plugin builds with full framework MSBuild, because assembly signing is unsupported
  under the cross platform build host

### Not yet verified

- Live metrics against a queue with callers waiting. `msdyn_queueextension` was empty
- Scheduled callback, its promotion flow and `RecordCallbackOutcome`
- A Copilot Studio agent calling any of it

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
