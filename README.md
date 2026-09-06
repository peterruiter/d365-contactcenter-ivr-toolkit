# Contact Center IVR Toolkit

Custom endpoints that let a Copilot Studio agent talk to Dynamics 365 Contact Center:
opening hours, live queue state, and callbacks. Built for voice, so every response
carries a phrase the agent can read out, and the whole thing is designed around one
composite call rather than a dozen chatty ones.

Ships as a managed Dataverse solution. Azure is optional and only for the MCP route.

## What it gives you

| Area | Endpoints |
|---|---|
| Queues | `GetQueues`, `ResolveQueue`, `GetQueueContext` |
| Hours | `GetQueueHours`, `IsQueueOpen`, `GetNextOpenTime` |
| Live state | `GetQueueMetrics` |
| Callback | `CheckCallbackEligibility`, `GetCallbackSlots`, `CreateCallback`, `GetCallbackStatus`, `CancelCallback`, `RescheduleCallback` |
| Utility | `ValidatePhoneNumber`, `GetBroadcastMessage`, `LogIvrOutcome`, `HealthCheck` |
| Internal | `PromoteDueCallbacks`, `RecordCallbackOutcome` (flows only, never exposed to agents) |

## Start here

New to the toolkit? Read in this order:

1. [Overview](docs/01-overview.md) - what it does and how it is put together
2. [Prerequisites](docs/02-prerequisites.md) - check before you install
3. [Installation](docs/03-installation.md) - guided first install
4. [Configuration](docs/04-configuration.md) - queue profiles, aliases, wording
5. [Copilot Studio](docs/06-copilot-studio.md) - wire it into your agent

Then keep [API reference](docs/05-api-reference.md) and
[Troubleshooting](docs/09-troubleshooting.md) open.

| Doc | Read when |
|---|---|
| [01 Overview](docs/01-overview.md) | Starting out, or explaining it to someone |
| [02 Prerequisites](docs/02-prerequisites.md) | Before any install |
| [03 Installation](docs/03-installation.md) | Installing |
| [04 Configuration](docs/04-configuration.md) | After install, and whenever hours or aliases change |
| [05 API reference](docs/05-api-reference.md) | Building an agent |
| [06 Copilot Studio](docs/06-copilot-studio.md) | Wiring the agent |
| [07 Scheduled callback](docs/07-scheduled-callback.md) | Only if callers pick a time |
| [08 Operations](docs/08-operations.md) | After go live |
| [09 Troubleshooting](docs/09-troubleshooting.md) | Something is wrong |
| [10 ALM and support](docs/10-alm-and-support.md) | Upgrading, or before the second client |
| [11 FAQ](docs/11-faq.md) | Quick answers |
| [12 MCP server](docs/12-mcp-server.md) | Deciding whether you need it. Usually not |
| [13 Reporting](docs/13-reporting.md) | The client asks whether it worked |
| [14 Tool descriptions](docs/14-tool-descriptions.md) | The agent keeps picking the wrong tool |

## Quick install

```powershell
dotnet tool install --global Microsoft.PowerApps.CLI.Tool
git clone <repo> && cd power-pete-ivr-toolkit
./build/Test-Prerequisites.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
./build/install.ps1

# Then the identity your agent connects as, and proof its role is sufficient
./build/New-ApplicationUser.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
./build/Test-Endpoints.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com `
    -TenantId <tenant> -ClientId <app> -ClientSecret <secret>
```

The installer prompts for locale, time zone, country code and wait band thresholds,
imports the solution, registers the Custom APIs and runs a health check.

Run the endpoint test with the application credentials rather than as yourself. An
administrator passes every check whether the security role is right or not.

## Which integration route

| Route | Azure | Latency | When |
|---|---|---|---|
| Dataverse connector, unbound actions | No | Lowest | Default. Start here |
| Custom connector | No | Low | Classic topic agents, Power Automate |
| MCP server | Container App | One extra hop | Several agents, or you want an audit point |

Most deployments need only the first. See [12 MCP server](docs/12-mcp-server.md) before
deploying infrastructure you may not need.

## Three things to know before you build on it

**Call `pwrp_GetQueueContext`, not the individual endpoints.** In a real-time voice
agent every tool call is silence the caller hears. One composite call answers open or
closed, how busy, is there an outage, and what to do next.

**Give callers `WaitBand`, never raw numbers.** The seconds are there for supervisors
and for your own tuning. "Fourteen callers ahead of you" is a hangup trigger.

**Live metrics read internal platform tables.** There is no supported real-time API.
Everything that touches them lives in one file, and `pwrp_HealthCheck` tells you when a
release wave has moved something. See [ALM and support](docs/10-alm-and-support.md).

## Repository map

```
build/          Build, install, deploy, schema, seed and validation scripts
                customapis.json is the contract. Everything else generates from it
connector/      Custom connector definition. Generated, do not hand edit
docs/           Fourteen documents, listed above
mcp/            Bicep and deployment notes for the optional MCP server
samples/        Copilot Studio instructions and topic wiring
solution/       Unpacked Dataverse solution, the model driven app and the promotion flow
src/            Plugin assembly, and the optional MCP server
tests/          Unit tests for the parts that break in production
```

## Generated artefacts

`build/customapis.json` is the single source of truth for the API surface. Three things
generate from it, so none of them can drift:

| Artefact | Generated by |
|---|---|
| Custom API metadata in Dataverse | `build/Register-CustomApis.ps1` |
| Custom connector swagger | `build/Build-Swagger.py` |
| MCP tool catalogue | `ToolCatalog.cs`, at server startup |

Change the contract, run the generators, commit.

## State

Built, deployed and exercised against a live Dynamics 365 Contact Center environment,
including a Copilot Studio voice agent calling it on a real call.

Proven end to end: queue context, callback slots, phone validation, direct and scheduled
callback booking, and outcome logging. The agent also handled a misrecognised queue name by
asking rather than guessing, which is the behaviour the resolver exists for.

Not yet proven: metrics against a queue with callers actually waiting, promotion through to
a dialled call, and cancel and reschedule. The promotion flow exists as of 3.4.0 and has
not run in anger. See `CHANGELOG.md`.

## Versioning and support

Semantic versioning. The Custom API contract is stable within a major version, so an
agent built against 1.x keeps working across 1.x upgrades. The version is written by hand
in `VERSION` alone; `build.ps1` raises the build number. See
[CHANGELOG.md](CHANGELOG.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

Open source, MIT licensed. Maintained by Power Pete. Raise issues in this repository.
