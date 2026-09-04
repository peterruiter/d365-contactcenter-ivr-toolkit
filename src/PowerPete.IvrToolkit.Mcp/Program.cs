using System.Text.Json.Nodes;
using PowerPete.IvrToolkit.Mcp;

// Streamable HTTP MCP server in front of the toolkit Custom APIs.
//
// This is optional. If your tenant can use the Dataverse connector's unbound actions,
// you do not need this at all and you save a hop. Deploy it when you want dynamic tool
// discovery, one endpoint shared across agents, or an audit point in front of Dataverse.

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddApplicationInsightsTelemetry();
builder.Services.AddHttpClient<DataverseClient>();
builder.Services.AddSingleton(_ => new ToolCatalog(
    Path.Combine(AppContext.BaseDirectory, "customapis.json"),
    builder.Configuration["Mcp:ExposedTools"]));

var app = builder.Build();

const string ProtocolVersion = "2025-06-18";

// Shared secret in a header. Copilot Studio sends it as a connector API key.
// Keep this even behind a private endpoint. Defence in depth costs nothing here.
app.Use(async (context, next) =>
{
    if (context.Request.Path == "/health")
    {
        await next();
        return;
    }

    var expected = app.Configuration["Mcp:ApiKey"];
    if (!string.IsNullOrWhiteSpace(expected))
    {
        var supplied = context.Request.Headers["x-pwrp-key"].FirstOrDefault();
        if (supplied != expected)
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }
    }

    await next();
});

app.MapGet("/health", () => Results.Ok(new { status = "ok", version = ProtocolVersion }));

app.MapPost("/mcp", async (
    HttpContext context,
    ToolCatalog catalog,
    DataverseClient dataverse,
    ILogger<Program> logger,
    CancellationToken cancellationToken) =>
{
    var request = await JsonNode.ParseAsync(context.Request.Body, cancellationToken: cancellationToken);
    if (request is not JsonObject envelope)
    {
        return Results.Json(Error(null, -32700, "Parse error"));
    }

    var id = envelope["id"]?.DeepClone();
    var method = envelope["method"]?.GetValue<string>();

    switch (method)
    {
        case "initialize":
            return Results.Json(Success(id, new JsonObject
            {
                ["protocolVersion"] = ProtocolVersion,
                ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
                ["serverInfo"] = new JsonObject
                {
                    ["name"] = "contact-center-ivr-toolkit",
                    ["version"] = "1.0.0"
                }
            }));

        case "notifications/initialized":
            return Results.StatusCode(StatusCodes.Status202Accepted);

        case "tools/list":
            return Results.Json(Success(id, new JsonObject
            {
                ["tools"] = new JsonArray(catalog.Tools.Select(tool => (JsonNode)new JsonObject
                {
                    ["name"] = tool.Name,
                    ["description"] = tool.Description,
                    ["inputSchema"] = tool.InputSchema.DeepClone()
                }).ToArray())
            }));

        case "tools/call":
        {
            var parameters = envelope["params"]?.AsObject();
            var name = parameters?["name"]?.GetValue<string>();
            var arguments = parameters?["arguments"]?.AsObject() ?? new JsonObject();

            var tool = name is null ? null : catalog.Find(name);
            if (tool is null)
            {
                return Results.Json(Error(id, -32602, $"Unknown tool '{name}'."));
            }

            try
            {
                var result = await dataverse.InvokeAsync(tool, arguments, cancellationToken);

                // Strip the OData wrapper. An agent should not have to know about it.
                result.Remove("@odata.context");

                var failed = result["Success"]?.GetValue<bool>() == false;

                return Results.Json(Success(id, new JsonObject
                {
                    ["content"] = new JsonArray(new JsonObject
                    {
                        ["type"] = "text",
                        ["text"] = result.ToJsonString()
                    }),
                    // isError tells the agent to handle it, not to retry blindly. Expected
                    // failures like QUEUE_AMBIGUOUS are answers, not errors, so this stays
                    // false and the agent reads ErrorCode.
                    ["isError"] = false
                }));
            }
            catch (TaskCanceledException)
            {
                logger.LogWarning("{Tool} timed out", tool.Name);
                return Results.Json(Success(id, new JsonObject
                {
                    ["content"] = new JsonArray(new JsonObject
                    {
                        ["type"] = "text",
                        ["text"] = """{"Success":false,"ErrorCode":"TIMEOUT","ErrorMessage":"The toolkit did not respond in time."}"""
                    }),
                    ["isError"] = false
                }));
            }
        }

        default:
            return Results.Json(Error(id, -32601, $"Method '{method}' is not supported."));
    }
});

app.Run();

static JsonObject Success(JsonNode? id, JsonObject result) => new()
{
    ["jsonrpc"] = "2.0",
    ["id"] = id,
    ["result"] = result
};

static JsonObject Error(JsonNode? id, int code, string message) => new()
{
    ["jsonrpc"] = "2.0",
    ["id"] = id,
    ["error"] = new JsonObject { ["code"] = code, ["message"] = message }
};
