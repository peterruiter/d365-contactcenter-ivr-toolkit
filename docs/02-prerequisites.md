# Prerequisites

Check every row before you start. Most failed installs trace back to one of these.

## Licences and provisioning

| Requirement | How to check |
|---|---|
| Dynamics 365 Contact Center, or Customer Service with the digital messaging add-on | Copilot Service admin centre loads |
| Voice channel provisioned | Channels > Manage channels shows Voice as provisioned |
| Unified routing enabled | Queues page shows queue type Voice as an option |
| At least one voice queue with representatives | Queues > your queue > Users |
| Copilot Studio licence | You can create an agent in the target environment |

Scheduled callback also needs:

| Requirement | Notes |
|---|---|
| Outbound calling configured | Outbound profile with a queue and capacity profile |
| A phone number enabled for outbound | Phone numbers page shows "Make calls" |
| An outbound workstream | The engagement hangs off this, and the toolkit finds it there |
| A proactive engagement on that workstream | Places the calls. Audience must be **CCaaS API** and the contact identifier must be **contactid**. Everything else is yours. See [scheduled callback](07-scheduled-callback.md) |

If you only need direct callback, skip that block. Direct callback is a queue overflow
setting and needs nothing extra.

## Building from source

Only needed if you build the plugin rather than installing a released solution.

| Requirement | Why |
|---|---|
| Visual Studio, or Build Tools for Visual Studio | The assembly merge signs the output, and signing is not supported under the cross platform build host. The .NET SDK alone is not enough |
| .NET SDK | Builds the optional MCP server |
| Python 3 | Regenerates the connector swagger from the contract |

## Permissions

- **System Administrator** on the target Dataverse environment for the install. The
  toolkit registers plugin types and Custom API metadata, which needs it.
- The service principal used by a pipeline needs the same.
- Day to day use needs only the **Power Pete IVR Reader** role shipped in the solution.
  Assign that to the application user your agent authenticates as.

## Tooling on the install machine

```powershell
# Power Platform CLI, 1.30 or later
dotnet tool install --global Microsoft.PowerApps.CLI.Tool
pac --version

# .NET SDK 8, for building from source
dotnet --version
```

You only need the .NET SDK if you are building the assembly. Installing a released
artefact needs `pac` alone.

## Environment sizing

Nothing unusual. The plugin is read heavy and short lived. Two notes:

- The metrics query scans open segments for one queue. On a queue with thousands of
  concurrent callers, raise `pwrp_MetricsCacheSeconds` before you worry about anything else.
- Scheduled callback writes one row per request. Plan retention if volumes are high.

## Before you go further

Run this to confirm the environment is ready:

```powershell
./build/Test-Prerequisites.ps1 -EnvironmentUrl https://yourorg.crm4.dynamics.com
```

It checks the tables the toolkit reads and tells you which are missing. Fix those
first. Installing over a half provisioned Contact Center produces confusing errors
later.
