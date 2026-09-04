using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Azure.Core;
using Azure.Identity;

namespace PowerPete.IvrToolkit.Mcp;

/// <summary>
/// Calls the toolkit Custom APIs over the Dataverse Web API.
///
/// Authenticates as a managed identity where one is available, falling back to a client
/// secret for local development. The identity needs the Power Pete IVR Reader role and nothing
/// more.
/// </summary>
public sealed class DataverseClient
{
    private readonly HttpClient _http;
    private readonly TokenCredential _credential;
    private readonly string _scope;
    private readonly ILogger<DataverseClient> _logger;
    private AccessToken _token;

    public DataverseClient(HttpClient http, IConfiguration configuration, ILogger<DataverseClient> logger)
    {
        _logger = logger;

        var environmentUrl = configuration["Dataverse:EnvironmentUrl"]
            ?? throw new InvalidOperationException("Dataverse:EnvironmentUrl is not configured.");

        _http = http;
        _http.BaseAddress = new Uri($"{environmentUrl.TrimEnd('/')}/api/data/v9.2/");
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        _http.Timeout = TimeSpan.FromSeconds(15);   // Voice budget. Never hang a call.

        _scope = $"{environmentUrl.TrimEnd('/')}/.default";

        var clientId = configuration["Dataverse:ClientId"];
        var clientSecret = configuration["Dataverse:ClientSecret"];
        var tenantId = configuration["Dataverse:TenantId"];

        _credential = !string.IsNullOrWhiteSpace(clientSecret)
            ? new ClientSecretCredential(tenantId, clientId, clientSecret)
            : new DefaultAzureCredential(new DefaultAzureCredentialOptions { ManagedIdentityClientId = clientId });
    }

    private async Task<string> GetTokenAsync(CancellationToken cancellationToken)
    {
        if (_token.ExpiresOn > DateTimeOffset.UtcNow.AddMinutes(5))
        {
            return _token.Token;
        }

        _token = await _credential.GetTokenAsync(new TokenRequestContext(new[] { _scope }), cancellationToken);
        return _token.Token;
    }

    /// <summary>
    /// Functions are a GET with inline parameters, actions are a POST. The catalogue knows
    /// which is which, so callers do not have to.
    /// </summary>
    public async Task<JsonObject> InvokeAsync(ToolCatalog.ToolDefinition tool, JsonObject arguments, CancellationToken cancellationToken)
    {
        var token = await GetTokenAsync(cancellationToken);

        using var request = tool.IsFunction
            ? new HttpRequestMessage(HttpMethod.Get, BuildFunctionUrl(tool.Name, arguments))
            : new HttpRequestMessage(HttpMethod.Post, tool.Name)
            {
                Content = new StringContent(arguments.ToJsonString(), Encoding.UTF8, "application/json")
            };

        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var started = DateTimeOffset.UtcNow;
        using var response = await _http.SendAsync(request, cancellationToken);
        var elapsed = (DateTimeOffset.UtcNow - started).TotalMilliseconds;

        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        _logger.LogInformation("{Tool} returned {Status} in {Elapsed:F0} ms", tool.Name, (int)response.StatusCode, elapsed);

        if (!response.IsSuccessStatusCode)
        {
            // The toolkit returns expected failures as 200 with Success = false, so a
            // non-success here is a real fault. Shape it like a toolkit error anyway,
            // because a voice agent should never see a platform fault.
            _logger.LogError("{Tool} failed: {Body}", tool.Name, body);
            return new JsonObject
            {
                ["Success"] = false,
                ["ErrorCode"] = "UPSTREAM_ERROR",
                ["ErrorMessage"] = "The toolkit could not be reached."
            };
        }

        return string.IsNullOrWhiteSpace(body)
            ? new JsonObject { ["Success"] = true }
            : JsonNode.Parse(body)!.AsObject();
    }

    private static string BuildFunctionUrl(string name, JsonObject arguments)
    {
        if (arguments.Count == 0)
        {
            return $"{name}()";
        }

        var parameters = arguments.Select(pair =>
        {
            var value = pair.Value;
            var literal = value is null ? "null"
                : value.GetValueKind() == JsonValueKind.Number || value.GetValueKind() == JsonValueKind.True || value.GetValueKind() == JsonValueKind.False
                    ? value.ToJsonString()
                    : $"'{Uri.EscapeDataString(value.GetValue<string>())}'";

            return $"{pair.Key}={literal}";
        });

        return $"{name}({string.Join(",", parameters)})";
    }
}
