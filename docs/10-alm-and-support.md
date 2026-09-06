# ALM, upgrades and support

The toolkit is reusable IP, not a one-off delivery. That changes how it is versioned,
shipped and owned.

## Versioning

Semantic versioning. The Custom API contract is what is versioned, not the internals.

| Change | Version bump |
|---|---|
| New endpoint | Minor |
| New optional input | Minor |
| New output property | Minor |
| Internal fix, same contract | Patch |
| Removed or renamed output | Major |
| Changed enum values | Major |
| Changed meaning of an existing output | Major |

An agent built against 1.x keeps working across every 1.x upgrade. That promise is the
reason clients will accept a dependency on this.

### Where the number lives

`VERSION` at the repository root, and nowhere else by hand. It holds
`MAJOR.MINOR.PATCH.BUILD`.

| Part | Who moves it | Appears as |
|---|---|---|
| `MAJOR.MINOR.PATCH` | You, by the table above | The release, and what `CHANGELOG.md` calls it |
| `BUILD` | `build.ps1`, every run | Nothing a person cites |

`build.ps1` raises the build number and stamps it into the two files that need their own
copy: the csproj for MSBuild and `Solution.xml` for `pac solution pack`. Pass
`-NoVersionBump` to rebuild what is already there, which is what you want for a packaging
change or a retry, and `-Version 3.4.0.7` to pin one.

Raising the build number on every build is not bookkeeping. Moving it is what makes the
Dataverse sandbox drop its cached copy of the assembly, so a build that reuses a number can
deploy and change nothing, which is a confusing hour.

The plugin assembly cannot carry the release version. Dataverse treats an assembly's major
and minor version as part of its identity, so moving either makes it a different assembly
and updating the registered one is refused, which means rebinding every Custom API. It
stays on 1.0 and takes the build number in its third part:

```
VERSION 3.4.0.9  ->  solution 3.4.0.9,  assembly 1.0.9.0
```

The build number is therefore the only thing tying an assembly to its release. An assembly
at 1.0.9.0 came from build 9, and the solution version says build 9 was 3.4.0.


## Build once, promote

`build/pipelines/azure-pipelines.yml` builds and publishes an artefact. Client
pipelines consume the published package. Never build per client. The moment two
clients run assemblies built from the same tag, you have lost the ability to reason
about a bug report.

The pipeline gates on `pwrp_HealthCheck` in a test environment. That gate is the point
of the whole thing.

## Upgrading a client

```powershell
# Sandbox first, always
./build/deploy.ps1 -EnvironmentUrl https://client-sandbox.crm4.dynamics.com -Version 1.2.0 -Managed
./build/Test-Installation.ps1 -EnvironmentUrl https://client-sandbox.crm4.dynamics.com

# Then production
./build/deploy.ps1 -EnvironmentUrl https://client-prod.crm4.dynamics.com -Version 1.2.0 -Managed
```

Environment variables survive a managed upgrade. Queue profiles, aliases, hours and
holidays survive. Callback and outcome data survives.

Re-run `Register-CustomApis.ps1` after every upgrade. It updates in place, which
preserves existing agent bindings.

## The dependency that needs owning

Live metrics read `msdyn_queueextension` and `msdyn_agentstatushistory`. There is no
supported public API for real-time contact centre metrics. The real-time dashboards
query these tables directly, so the toolkit does the same.

**What that means in practice:**

- The schema can change in a release wave without notice
- Everything that touches it lives in `Metrics/QueueMetricsReader.cs`, so a break is a
  single file fix
- `pwrp_HealthCheck` detects it
- When metrics fail, the agent carries on without wait times rather than dropping the
  call

**What it does not mean:** that the toolkit is fragile. Hours, queue resolution and
callbacks use supported schema and are unaffected.

Write this into the client's documentation. Discovering it during an incident is much
worse than reading it during a design review.

## Release wave routine

Contact Center release waves land twice a year, with early access ahead of general
availability.

1. Enable early access in an internal sandbox
2. Run the health check
3. If metrics fail, fix the reader and cut a patch release
4. Publish the patch before the wave reaches clients

Two people should be able to do this. One is a single point of failure, and the
toolkit becomes shelfware the moment they move on.

## Support model

Decide this before the second client. Reusable IP with a plugin dependency needs a
named owner.

| Question | Needs an answer |
|---|---|
| Who fixes it when a wave breaks the metrics reader | A named person and a backup |
| What response time do clients get | Write it into the engagement |
| Who pays for maintenance | Overhead, or a per client fee |
| How are clients told about a new version | A list, not word of mouth |
| How long is a major version supported | Set it, so migrations have a deadline |

Skip this and the pattern is predictable: two happy clients, a wave update, an
unavailable owner, and a client whose IVR quietly stops quoting wait times.

## Adding a client specific extension

Do not fork. Create a separate solution that depends on this one, and put client
specific Custom APIs in the `pwrp_` publisher's client prefix. The toolkit upgrades
independently.

If three clients ask for the same extension, that is the signal to bring it into the
core and version it properly.
