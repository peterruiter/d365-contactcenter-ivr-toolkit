# Solution folder

Holds the unpacked Dataverse solution that `pac solution pack` builds into the artefact,
plus the promotion flow definition.

Solution XML is generated from a development environment by `Export-Solution.ps1`, not
written by hand. Edit the environment, then export.

## Bootstrapping a development environment

In this order. Each step needs the one before it.

```powershell
$env = "https://mydev.crm4.dynamics.com"

# 1. Tables, columns, environment variables, and the security role
./build/New-Schema.ps1 -EnvironmentUrl $env

# 2. Put the columns on the forms and default views.
#    Dataverse builds a form when the table is created, so it holds the primary column
#    and the owner and nothing else. Without this every record looks empty.
./build/Update-Forms.ps1 -EnvironmentUrl $env

# 3. Build the plugin, then get it into the environment.
#    Import-PluginAssembly.ps1 is the development route, and exists because the Custom
#    APIs need plugin types, which need a registered assembly, which normally arrives in
#    a solution that cannot be packed until the components exist.
./build/build.ps1 -Version 1.0.0
./build/Import-PluginAssembly.ps1 -EnvironmentUrl $env
./build/Register-CustomApis.ps1 -EnvironmentUrl $env

# 4. Configuration and the app
./build/New-QueueProfiles.ps1 -EnvironmentUrl $env
./build/New-ModelDrivenApp.ps1 -EnvironmentUrl $env
./build/Seed-Data.ps1 -EnvironmentUrl $env          # real holidays and templates
./build/New-DemoData.ps1 -EnvironmentUrl $env       # sample content, development only

# 5. The identity an agent connects as, and proof the role is enough
./build/New-ApplicationUser.ps1 -EnvironmentUrl $env
./build/Test-Installation.ps1 -EnvironmentUrl $env
./build/Test-Endpoints.ps1 -EnvironmentUrl $env -TenantId <t> -ClientId <c> -ClientSecret <s>

# 6. Export and unpack, then commit
./build/Export-Solution.ps1 -EnvironmentUrl $env
```

Run `Test-Endpoints.ps1` with the application credentials rather than as yourself. As an
administrator everything passes whether the security role is right or not.

From then on the pipeline packs the committed folder, and `New-Schema.ps1` and
`Update-Forms.ps1` are only needed when the schema changes.

## Schema

Defined in [build/schema.json](../build/schema.json), which `New-Schema.ps1` reads.
Eight tables, 49 columns. Summary below; the JSON is authoritative.

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

**Contact Center IVR Toolkit**, created by `build/New-ModelDrivenApp.ps1`. Sitemap order
matters, because admins live in two of these areas and visit the rest rarely:

1. Broadcast messages
2. Queue aliases
3. Callback requests
4. Queue profiles
5. Queue hours
6. Holidays
7. IVR outcomes
8. Message templates

A second group, **Settings**, holds one entry:

9. Settings, the `pwrp_settings` HTML web resource

`pwrp_broadcastmessage` shows the active messages view by default. An admin publishing an
outage message under pressure should not have to filter first.

Settings is a page, not a table. The obvious alternative, a subarea over
`environmentvariabledefinition`, was tried and abandoned:

- Both settings tables are managed platform tables shared with every other solution in the
  environment, so the grid lists everybody's variables
- A filtered view on them is refused outright, failing on the `isparentcustomizable`
  managed property with a message about component evaluation that never mentions views
- A definition and its value are two records in two tables, so changing a setting means
  editing a row the first screen only hints at

`src/webresources/pwrp_settings.html` reads the definitions, writes the values, marks
which settings are on their default, reverts one by deleting its value row, and runs
`pwrp_HealthCheck`. It is uploaded and published by `New-ModelDrivenApp.ps1` and added to
the app as a component, because a subarea pointing at a web resource the app does not list
renders an empty pane rather than an error.

Everything the page displays except the grouping comes from the definitions, so the
guidance has one source. A setting added later and not in the page's group list still
appears, under Other, with its guidance intact.

Guidance for each setting is the Description on its definition, written by
`build/New-Schema.ps1` from `build/schema.json`. Change the wording there rather than in
the environment, or the next run overwrites it.

Icons come from the platform's own set under `/_imgs/TableIconsFluentV9`. It is a short
list, and a path that does not resolve renders as a blank square rather than failing, so
check any new one before using it. Do not borrow an icon from another solution's web
resources: they work, and they make this solution depend on Field Service or Omnichannel
being installed.

The app's own tile icon is different: it is an SVG web resource, `pwrp_/icons/ivrtoolkit.svg`,
uploaded from `build/assets/app-icon.svg`. Without it the app shows the platform default
tile, which several other apps also show. Edit the SVG in the repository and re-run
`New-ModelDrivenApp.ps1`; do not edit the web resource in the environment.

Binding it to the app is done by finding the `appmodule` lookup whose target is
`webresource` and using that relationship's navigation property name. Do not shorten this
to the attribute name. The attribute is not called `webresourceid`, and an `@odata.bind`
on a name that is not a navigation property fails inside the OData deserialiser with a
stack trace that mentions neither lookups nor icons.

It is line art in one accent colour on a transparent ground. The app selector renders the
tile on dark navy and the maker portal renders it on white, and an icon designed for one
of those is unreadable on the other.

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
