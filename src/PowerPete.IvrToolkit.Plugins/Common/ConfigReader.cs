using System;
using System.Collections.Generic;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace PowerPete.IvrToolkit.Common
{
    /// <summary>
    /// Reads environment variables shipped with the solution.
    /// Values are cached per plugin execution to avoid repeat retrieval on a composite call.
    /// </summary>
    public class ConfigReader
    {
        private readonly IOrganizationService _service;
        private readonly Dictionary<string, string> _cache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public ConfigReader(IOrganizationService service)
        {
            _service = service;
        }

        public string GetString(string schemaName, string fallback = null)
        {
            if (_cache.TryGetValue(schemaName, out var cached))
            {
                return cached ?? fallback;
            }

            var query = new QueryExpression("environmentvariabledefinition")
            {
                ColumnSet = new ColumnSet("defaultvalue", "schemaname"),
                Criteria = { Conditions = { new ConditionExpression("schemaname", ConditionOperator.Equal, schemaName) } },
                TopCount = 1
            };

            var values = query.AddLink("environmentvariablevalue", "environmentvariabledefinitionid", "environmentvariabledefinitionid", JoinOperator.LeftOuter);
            values.EntityAlias = "v";
            values.Columns = new ColumnSet("value");

            var result = _service.RetrieveMultiple(query);
            string resolved = null;

            if (result.Entities.Count > 0)
            {
                var row = result.Entities[0];
                if (row.Contains("v.value") && row["v.value"] is AliasedValue aliased && aliased.Value is string overridden && !string.IsNullOrWhiteSpace(overridden))
                {
                    resolved = overridden;
                }
                else
                {
                    resolved = row.GetAttributeValue<string>("defaultvalue");
                }
            }

            _cache[schemaName] = resolved;
            return string.IsNullOrWhiteSpace(resolved) ? fallback : resolved;
        }

        public int GetInt(string schemaName, int fallback)
        {
            var raw = GetString(schemaName);
            return int.TryParse(raw, out var parsed) ? parsed : fallback;
        }

        public bool GetBool(string schemaName, bool fallback)
        {
            var raw = GetString(schemaName);
            return bool.TryParse(raw, out var parsed) ? parsed : fallback;
        }
    }

    /// <summary>Schema names of every environment variable the toolkit reads.</summary>
    public static class ConfigKeys
    {
        public const string DefaultLocale = "pwrp_DefaultLocale";
        public const string MetricsCacheSeconds = "pwrp_MetricsCacheSeconds";
        public const string HoursCacheSeconds = "pwrp_HoursCacheSeconds";
        public const string WaitBandThresholds = "pwrp_WaitBandThresholds";
        public const string MetricsWindowMinutes = "pwrp_MetricsWindowMinutes";
        public const string EnableScheduledCallback = "pwrp_EnableScheduledCallback";
        public const string OutboundWorkstreamId = "pwrp_OutboundWorkstreamId";
        public const string MaxCallbackAttempts = "pwrp_MaxCallbackAttempts";
        public const string CallbackRetryMinutes = "pwrp_CallbackRetryMinutes";
        public const string CallbackSlotMinutes = "pwrp_CallbackSlotMinutes";
        public const string DefaultCountryCode = "pwrp_DefaultCountryCode";
        public const string DefaultTimeZone = "pwrp_DefaultTimeZone";
        public const string TelemetryEnabled = "pwrp_TelemetryEnabled";
    }
}
