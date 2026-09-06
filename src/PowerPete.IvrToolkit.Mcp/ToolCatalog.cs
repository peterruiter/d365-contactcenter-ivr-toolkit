using System.Text.Json;
using System.Text.Json.Nodes;

namespace PowerPete.IvrToolkit.Mcp;

/// <summary>
/// Builds the MCP tool list from build/customapis.json.
///
/// Generating rather than hand writing matters more than it looks. Tool names and
/// descriptions drive orchestration in a generative agent, so a drift between what the
/// API accepts and what the tool advertises shows up as the agent calling the wrong
/// thing, which is much harder to diagnose than a 400.
/// </summary>
public sealed class ToolCatalog
{
    public record ToolDefinition(string Name, string Description, JsonObject InputSchema, bool IsFunction, bool IsPrivate);

    private readonly List<ToolDefinition> _tools = new();
    private readonly Dictionary<string, ToolDefinition> _byName = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Tools exposed by default. Everything else is available but hidden, because an
    /// agent given nineteen tools picks badly. Override with PWRP_EXPOSED_TOOLS.
    ///
    /// The same nine that docs/06-copilot-studio.md sets up over the Dataverse connector.
    /// Two routes to the same toolkit that disagree about what an agent needs is a bug in
    /// the product, and it was one: scheduled callback was default here and optional there.
    ///
    /// pwrp_RescheduleCallback replaced pwrp_GetNextOpenTime rather than joining it. Nine
    /// is the budget. GetNextOpenTime answers what GetQueueContext already returned in
    /// OpenState, so it was the one paying for a seat twice.
    /// </summary>
    private static readonly string[] DefaultExposed =
    {
        "pwrp_GetQueueContext",
        "pwrp_GetQueueHours",
        "pwrp_ValidatePhoneNumber",
        "pwrp_GetCallbackSlots",
        "pwrp_CreateCallback",
        "pwrp_GetCallbackStatus",
        "pwrp_CancelCallback",
        "pwrp_RescheduleCallback",
        "pwrp_LogIvrOutcome"
    };

    public ToolCatalog(string definitionPath, string? exposedOverride)
    {
        var document = JsonNode.Parse(File.ReadAllText(definitionPath))!.AsObject();
        var exposed = string.IsNullOrWhiteSpace(exposedOverride)
            ? DefaultExposed
            : exposedOverride.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        foreach (var node in document["apis"]!.AsArray())
        {
            var api = node!.AsObject();
            var name = api["name"]!.GetValue<string>();

            var isPrivate = api["isPrivate"]?.GetValue<bool>() ?? false;
            if (isPrivate || !exposed.Contains(name, StringComparer.OrdinalIgnoreCase))
            {
                continue;
            }

            var properties = new JsonObject();
            var required = new JsonArray();

            foreach (var inputNode in api["inputs"]!.AsArray())
            {
                var input = inputNode!.AsObject();
                var inputName = input["name"]!.GetValue<string>();

                properties[inputName] = new JsonObject
                {
                    ["type"] = MapType(input["type"]!.GetValue<string>()),
                    ["description"] = input["description"]?.GetValue<string>() ?? inputName
                };

                if (input["required"]?.GetValue<bool>() == true)
                {
                    required.Add(inputName);
                }
            }

            var schema = new JsonObject
            {
                ["type"] = "object",
                ["properties"] = properties,
                ["required"] = required
            };

            var tool = new ToolDefinition(
                name,
                BuildDescription(api),
                schema,
                api["isFunction"]?.GetValue<bool>() ?? true,
                isPrivate);

            _tools.Add(tool);
            _byName[name] = tool;
        }
    }

    /// <summary>
    /// Description plus the outputs the agent will get back. Listing the outputs stops the
    /// model inventing property names when it writes a follow-up turn.
    /// </summary>
    private static string BuildDescription(JsonObject api)
    {
        var description = api["description"]!.GetValue<string>();
        var outputs = api["outputs"]!.AsArray()
            .Select(o => o!.AsObject()["name"]!.GetValue<string>());

        return $"{description} Returns: {string.Join(", ", outputs)}, plus Success and ErrorCode.";
    }

    private static string MapType(string dataverseType) => dataverseType switch
    {
        "Boolean" => "boolean",
        "Integer" or "Decimal" or "Float" => "number",
        _ => "string"
    };

    public IReadOnlyList<ToolDefinition> Tools => _tools;

    public ToolDefinition? Find(string name) => _byName.TryGetValue(name, out var tool) ? tool : null;
}
