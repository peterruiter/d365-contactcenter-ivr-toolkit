---
description: Check the contract and its generated artefacts are consistent
---

Verify the toolkit contract is internally consistent. Report findings, fix what is
clearly wrong, ask about anything ambiguous.

Check all of these:

1. **Swagger is current.** Run `python3 build/Build-Swagger.py` and
   `git diff --exit-code connector/apiDefinition.swagger.json`. A diff means someone
   hand edited it.

2. **Every API in `customapis.json` has a handler.** The `type` field must match a real
   class in `src/PowerPete.IvrToolkit.Plugins/CustomApis/`.

3. **Every handler sets every declared output.** An output declared in the contract but
   never set returns null to the agent, which is worse than a missing output.

4. **Every API is documented.** `docs/05-api-reference.md` should have a section for
   each public API, with matching input and output names.

5. **Error codes match.** Every code in `ErrorCodes` should appear in the error table in
   `docs/05-api-reference.md`, and every code thrown in the source should be in
   `ErrorCodes`.

6. **Private APIs are not exposed.** Nothing with `isPrivate: true` should be in
   `DefaultExposed` in `ToolCatalog.cs` or in the generated swagger.

7. **Speakable outputs exist** on any endpoint an agent reads from.

8. **Schema references resolve.** Every `pwrp_` table and column referenced in the C#
   should exist in `build/schema.json`.

Report as a table: check, pass or fail, and what to do about it.
