---
description: Correct platform table references against real Dataverse metadata
---

Fix the internal platform schema references in the toolkit against real metadata.

Context: the readers were written against documentation, not against a live
environment. Attribute names, option set values and relationship names are all
unverified.

Files that touch internal platform schema, and nothing else should:

- `src/PowerPete.IvrToolkit.Plugins/Metrics/QueueMetricsReader.cs`
- `src/PowerPete.IvrToolkit.Plugins/Hours/OperatingHoursProvider.cs`
- `src/PowerPete.IvrToolkit.Plugins/Queues/QueueResolver.cs` (the `queue` table only)

Metadata to pull, if an environment is available:

```
GET /api/data/v9.2/EntityDefinitions(LogicalName='msdyn_queueextension')/Attributes?$select=LogicalName,AttributeType
GET /api/data/v9.2/EntityDefinitions(LogicalName='msdyn_ocliveworkitem')/Attributes?$select=LogicalName,AttributeType
GET /api/data/v9.2/EntityDefinitions(LogicalName='msdyn_agentstatushistory')/Attributes?$select=LogicalName,AttributeType
GET /api/data/v9.2/EntityDefinitions(LogicalName='queue')/Attributes?$select=LogicalName,AttributeType
GET /api/data/v9.2/EntityDefinitions(LogicalName='msdyn_operatinghour')/ManyToOneRelationships
```

Rules while fixing:

- Keep every platform table reference inside the file it is already in. The isolation is
  the whole point.
- Record what you confirmed in a comment, with the date. The next person should not
  repeat the exercise.
- If an attribute does not exist and there is no obvious replacement, do not guess.
  Raise it and stop.
- Add a health check assertion for anything new you depend on.
- Do not weaken the failure handling. A metrics failure must still degrade rather than
  fail the call.

Arguments, if given, narrow the scope: $ARGUMENTS
