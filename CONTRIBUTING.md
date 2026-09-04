# Contributing

This is reusable IP, not a delivery artefact. That changes the bar.

## Before you change anything

Ask which of these you are touching:

| Layer | Bar |
|---|---|
| Custom API contract | High. Every client agent depends on it. Version it properly |
| Services | Normal. Unit tested where the logic is real |
| Platform schema readers | Isolated by design. Keep them in one file each |
| Docs | Same bar as code. A wrong doc costs more than a missing one |

## Changing the contract

`build/customapis.json` is the contract. It is also the source for the connector swagger
and the MCP tool catalogue, so a change there propagates to both.

1. Edit `customapis.json`
2. Run `python3 build/Build-Swagger.py`
3. Update `docs/05-api-reference.md`
4. Add a `CHANGELOG.md` entry with the right version bump

Do not hand edit `connector/apiDefinition.swagger.json`. It is generated and your edit
will be overwritten.

### Version bumps

| Change | Bump |
|---|---|
| New endpoint, new optional input, new output property | Minor |
| Description change (behaviour change in a generative agent) | Minor |
| Internal fix, same contract | Patch |
| Removed or renamed output, changed enum values, changed meaning | Major |

An agent built against 1.x must keep working across every 1.x upgrade. That promise is
why clients accept a dependency on this.

## Touching the metrics reader

`Metrics/QueueMetricsReader.cs` reads internal platform tables. Rules:

- Everything that touches those tables stays in that file
- Never let a metrics failure fail a call. Throw `ToolkitException` with
  `METRICS_UNAVAILABLE` and let the composite endpoint degrade
- Add a health check assertion for anything new you depend on

The same applies to `Hours/OperatingHoursProvider.cs`.

## Tests

Unit tests cover the logic that breaks in production: fuzzy matching, wait banding,
phone normalisation, date maths.

Dataverse query paths are not unit tested. Faking `msdyn_queueextension` would only test
the fake. Those are covered by running against a real environment.

```powershell
dotnet test
```

Tests must pass before the solution packs. `build.ps1` enforces it.

## Adding a locale

1. Add a block to `Speech/SpeakableFormatter.Strings`
2. Add the matching rows to `Seed-Data.ps1`
3. Have a native speaker read the output aloud

That third step is not optional. Phrases that read fine look wrong when spoken, and
time formats in particular go wrong in ways that only sound obvious.

## Client specific work

Do not fork. Create a separate solution that depends on this one and put client
specific APIs under a client prefix. The toolkit upgrades independently.

If three clients ask for the same thing, that is the signal to bring it into the core
and version it.

## Pull requests

- One concern per pull request
- Contract changes and implementation changes in separate commits
- Say in the description what a client would have to do differently after merging. If
  the answer is nothing, say that
