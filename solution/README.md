# Solution folder

Holds the unpacked Dataverse solution that `pac solution pack` builds into the artefact,
plus the promotion flow definition.

**Empty in the repository as published**, apart from `Workflows/`. Solution XML is
generated from a development environment, not written by hand.

## Bootstrapping a development environment

```powershell
# 1. Create the schema, environment variables and choices
./build/New-Schema.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com

# 2. Create the model driven app by hand (see below)
#    New-Schema.ps1 already created the security role. To redo just that:
#    ./build/New-SecurityRole.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com

# 3. Build and import the plugin assembly, then register the Custom APIs
./build/build.ps1
./build/Register-CustomApis.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com

# 4. Import the promotion flow from solution/Workflows

# 5. Export and unpack, then commit
./build/Export-Solution.ps1 -EnvironmentUrl https://mydev.crm4.dynamics.com
```

From then on the pipeline packs the committed folder and `New-Schema.ps1` is only needed
when the schema changes.

## Schema

Defined in [build/schema.json](../build/schema.json), which `New-Schema.ps1` reads.
Eight tables, 48 columns. Summary below; the JSON is authoritative.

| Table | Purpose |
|---|---|
| `pwrp_queueprofile` | Per queue settings: speakable name, hours source, callback options |
| `pwrp_queuealias` | Every way a caller might name a queue |
| `pwrp_queuehours` | Weekly opening windows, when using toolkit config hours |
| `pwrp_holiday` | Date overrides, organisation wide or per queue |
| `pwrp_callbackrequest` | Requested callbacks, with status, attempts and retry state |
| `pwrp_broadcastmessage` | Outage announcements |
| `pwrp_ivroutcome` | One row per conversation, for containment reporting |
| `pwrp_messagetemplate` | Spoken phrase overrides, per locale |

### Indexes worth adding by hand

The metadata API does not create these. Add them in the maker portal.

| Table | Columns | Why |
|---|---|---|
| `pwrp_callbackrequest` | `pwrp_phonenumber`, `pwrp_status` | Deduplication runs on every callback creation |
| `pwrp_callbackrequest` | `pwrp_requestedstart`, `pwrp_status` | The promotion query runs every five minutes |
| `pwrp_ivroutcome` | `pwrp_occurredon` | Every report filters on it |

## Security role

**Power Pete IVR Reader**, assigned to the application user the agent authenticates as.
Privileges are listed in `build/schema.json` under `securityRole`.

`New-Schema.ps1` creates it, or run `build/New-SecurityRole.ps1` on its own. Privilege ids
differ per environment, so they are read from entity metadata at run time rather than
hard coded. The privilege set is replaced on every run, so the role always matches
`schema.json`.

Scripting it also reaches tables the role editor will not show you: `queuemembership` is
an intersect entity, `msdyn_ocliveworkitem` is not surfaced, and `environmentvariablevalue`
is not where you would look for it.

### Why the role reads plugintype and pluginassembly

Nothing in the toolkit queries either table. The platform reads them when it resolves a
Custom API to the code behind it, so a caller without them gets

    is missing prvReadPluginType privilege ... for entity 'plugintype'

and the API never runs. Confirmed on 2026-09-04 by calling every endpoint as the
application user rather than as an administrator, which is the only way this shows up.

That test is worth repeating rather than trusting once. The failure moves between
endpoints from run to run, because whichever call warms the metadata cache first succeeds
and the rest do not. Two clean runs mean more than one.

Do not substitute System Administrator. The toolkit is built to run on this role and the
health check assumes it.

## Model driven app

**Contact Center IVR Toolkit**. Sitemap order matters, because admins live in two of
these areas and visit the rest rarely:

1. Broadcast messages
2. Queue aliases
3. Callback requests
4. Queue profiles
5. Queue hours
6. Holidays
7. IVR outcomes
8. Message templates

Give `pwrp_broadcastmessage` a view filtered to active messages as the default. An admin
publishing an outage message under pressure should not have to filter first.

## Workflows

`Workflows/PowerPete-Promote-Due-Callbacks.json` is the scheduled callback promotion flow.
Recurrence every five minutes, calls `pwrp_PromoteDueCallbacks`, fails loudly on a
configuration error.

Deliberately thin. All branching, date maths and the retry policy live in the plugin
where they can be unit tested and read in a pull request. See
[docs/07-scheduled-callback.md](../docs/07-scheduled-callback.md).

Turn it off in environments where `pwrp_EnableScheduledCallback` is false. It does
nothing there, but a flow running every five minutes to do nothing is noise in the run
history.
