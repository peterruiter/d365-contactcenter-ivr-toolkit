---
description: Add a new Custom API endpoint end to end
---

Add a new endpoint to the Contact Center IVR Toolkit: $ARGUMENTS

Work through every step. Do not stop halfway, an endpoint that exists in one place and
not the others is worse than no endpoint.

1. **Decide whether it should exist.** Check `docs/05-api-reference.md` first. If an
   existing endpoint already answers the question, say so and stop. The surface is
   deliberately small.

2. **Contract.** Add the definition to `build/customapis.json`. Write the description
   the way `docs/14-tool-descriptions.md` says: what it answers, not what it queries.
   Set `isFunction` correctly, and `isPrivate` true if it is for flows rather than
   agents.

3. **Implementation.** Add the handler to the right file in
   `src/PowerPete.IvrToolkit.Plugins/CustomApis/`. Inherit `ToolkitPluginBase`. Put real
   logic in a service class, not in the handler.

4. **Speakable output.** If an agent will read from it, add a `Speakable` output and a
   template in `SpeakableFormatter` for both nl-NL and en-GB.

5. **Errors.** Any new failure mode needs a code in `ErrorCodes` and a row in the error
   table in `docs/05-api-reference.md`.

6. **Regenerate.** `python3 build/Build-Swagger.py`

7. **MCP exposure.** Decide whether it belongs in `DefaultExposed` in `ToolCatalog.cs`.
   Default is no. If yes, remove something else. Nine is the ceiling.

8. **Docs.** Add a section to `docs/05-api-reference.md` matching the existing format.

9. **Tests.** If it has real logic, test it. If it is a thin wrapper over a service that
   is already tested, say so instead of writing a test that asserts nothing.

10. **Changelog.** Minor bump, entry in `CHANGELOG.md`.

11. **Build.** `dotnet build -c Release && dotnet test`

Report what you changed and whether anything downstream needs a client action.
