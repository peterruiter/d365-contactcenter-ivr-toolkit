using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Model;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace PowerPete.IvrToolkit.Queues
{
    /// <summary>
    /// Turns whatever the agent supplies into a queue.
    ///
    /// A speech-driven IVR never has a GUID, so name resolution is the primary path.
    /// Resolution order:
    ///   1. GUID, if the input parses as one
    ///   2. Exact alias match in pwrp_queuealias (case insensitive)
    ///   3. Exact queue name match
    ///   4. Fuzzy match against aliases and names, above the configured confidence floor
    /// A fuzzy result that ties with another candidate raises QUEUE_AMBIGUOUS so the
    /// agent asks a clarifying question instead of guessing.
    /// </summary>
    public class QueueResolver
    {
        private const int FuzzyFloor = 78;

        private readonly IOrganizationService _service;
        private readonly ConfigReader _config;
        private readonly ITracingService _tracing;

        public QueueResolver(IOrganizationService service, ConfigReader config, ITracingService tracing)
        {
            _service = service;
            _config = config;
            _tracing = tracing;
        }

        public QueueRef Resolve(string queueIdOrName)
        {
            if (string.IsNullOrWhiteSpace(queueIdOrName))
            {
                throw new ToolkitException(ErrorCodes.InvalidInput, "Supply a queue name or queue id.");
            }

            var all = LoadProfiles();

            if (Guid.TryParse(queueIdOrName, out var queueId))
            {
                var byId = all.FirstOrDefault(q => q.QueueId == queueId);
                if (byId == null)
                {
                    throw new ToolkitException(ErrorCodes.QueueNotFound, "No queue matches that id.");
                }
                return byId;
            }

            var needle = Normalise(queueIdOrName);

            var exact = all.FirstOrDefault(q => Normalise(q.Name) == needle)
                        ?? all.FirstOrDefault(q => AliasesFor(q).Any(a => Normalise(a) == needle));
            if (exact != null)
            {
                return exact;
            }

            var scored = all
                .Select(q => new
                {
                    Queue = q,
                    Score = new[] { Similarity(needle, Normalise(q.Name)) }
                        .Concat(AliasesFor(q).Select(a => Similarity(needle, Normalise(a))))
                        .Max()
                })
                .Where(x => x.Score >= FuzzyFloor)
                .OrderByDescending(x => x.Score)
                .ToList();

            if (scored.Count == 0)
            {
                throw new ToolkitException(ErrorCodes.QueueNotFound, $"No queue matches '{queueIdOrName}'.");
            }

            if (scored.Count > 1 && scored[0].Score - scored[1].Score < 6)
            {
                var options = string.Join(", ", scored.Take(3).Select(x => x.Queue.SpeakableName));
                throw new ToolkitException(ErrorCodes.QueueAmbiguous, $"More than one queue matches. Candidates: {options}.");
            }

            _tracing.Trace("[pwrp] fuzzy matched '{0}' to '{1}' at {2}", queueIdOrName, scored[0].Queue.Name, scored[0].Score);
            return scored[0].Queue;
        }

        public List<QueueRef> ListQueues(string channelType)
        {
            var all = LoadProfiles();
            return string.IsNullOrWhiteSpace(channelType)
                ? all
                : all.Where(q => string.Equals(q.ChannelType, channelType, StringComparison.OrdinalIgnoreCase)).ToList();
        }

        private readonly Dictionary<Guid, List<string>> _aliasCache = new Dictionary<Guid, List<string>>();

        private IEnumerable<string> AliasesFor(QueueRef queue)
        {
            return _aliasCache.TryGetValue(queue.QueueId, out var aliases) ? aliases : Enumerable.Empty<string>();
        }

        /// <summary>
        /// Loads queues joined to their pwrp_queueprofile row. Queues without a profile are
        /// still returned so a partial install degrades rather than fails, but they get
        /// default banding and no speakable name override.
        /// </summary>
        private List<QueueRef> LoadProfiles()
        {
            var ttl = _config.GetInt(ConfigKeys.HoursCacheSeconds, 300);

            return CacheStore.GetOrAdd("queues:all", ttl, () =>
            {
                var query = new QueryExpression("queue")
                {
                    ColumnSet = new ColumnSet("queueid", "name", "msdyn_queuetype"),
                    Criteria =
                    {
                        Conditions = { new ConditionExpression("statecode", ConditionOperator.Equal, 0) }
                    }
                };

                var profile = query.AddLink("pwrp_queueprofile", "queueid", "pwrp_queueid", JoinOperator.LeftOuter);
                profile.EntityAlias = "p";
                profile.Columns = new ColumnSet("pwrp_queueprofileid", "pwrp_speakablename", "pwrp_timezone", "pwrp_locale", "pwrp_countrycode");

                var results = _service.RetrieveMultiple(query).Entities
                    .Select(e => new QueueRef
                    {
                        QueueId = e.GetAttributeValue<Guid>("queueid"),
                        Name = e.GetAttributeValue<string>("name"),
                        SpeakableName = Alias<string>(e, "p.pwrp_speakablename") ?? e.GetAttributeValue<string>("name"),
                        ChannelType = MapChannel(e.GetAttributeValue<OptionSetValue>("msdyn_queuetype")),
                        TimeZone = Alias<string>(e, "p.pwrp_timezone") ?? _config.GetString(ConfigKeys.DefaultTimeZone, "W. Europe Standard Time"),
                        Locale = Alias<string>(e, "p.pwrp_locale") ?? _config.GetString(ConfigKeys.DefaultLocale, "nl-NL"),
                        CountryCode = Alias<string>(e, "p.pwrp_countrycode") ?? _config.GetString(ConfigKeys.DefaultCountryCode, "31"),
                        ProfileId = Alias<Guid?>(e, "p.pwrp_queueprofileid")
                    })
                    .ToList();

                LoadAliases(results);
                return results;
            });
        }

        private void LoadAliases(List<QueueRef> queues)
        {
            _aliasCache.Clear();
            var query = new QueryExpression("pwrp_queuealias")
            {
                ColumnSet = new ColumnSet("pwrp_name", "pwrp_queueid"),
                Criteria = { Conditions = { new ConditionExpression("statecode", ConditionOperator.Equal, 0) } }
            };

            foreach (var row in _service.RetrieveMultiple(query).Entities)
            {
                var reference = row.GetAttributeValue<EntityReference>("pwrp_queueid");
                var alias = row.GetAttributeValue<string>("pwrp_name");
                if (reference == null || string.IsNullOrWhiteSpace(alias))
                {
                    continue;
                }

                if (!_aliasCache.TryGetValue(reference.Id, out var list))
                {
                    list = new List<string>();
                    _aliasCache[reference.Id] = list;
                }
                list.Add(alias);
            }
        }

        private static T Alias<T>(Entity entity, string key)
        {
            return entity.Contains(key) && entity[key] is AliasedValue aliased && aliased.Value is T typed ? typed : default(T);
        }

        /// <summary>Maps msdyn_queuetype to the channel names the contract uses.</summary>
        /// <remarks>
        /// Values confirmed against a real environment, 2026-09-04. The platform labels
        /// 192350001 "Entity"; the contract calls it "Record", which is the word an agent
        /// author expects. Deliberate, and renaming it would be a breaking contract change.
        /// </remarks>
        private static string MapChannel(OptionSetValue value)
        {
            if (value == null) return "Unknown";
            switch (value.Value)
            {
                case 192350000: return "Messaging";
                case 192350001: return "Record";
                case 192350002: return "Voice";
                default: return "Unknown";
            }
        }

        /// <summary>Lowercase, strip punctuation, collapse whitespace. Speech output is messy.</summary>
        private static string Normalise(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return string.Empty;
            var chars = value.ToLowerInvariant().Where(c => char.IsLetterOrDigit(c) || c == ' ').ToArray();
            return string.Join(" ", new string(chars).Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries));
        }

        /// <summary>Levenshtein similarity as a percentage. Good enough, and it runs in microseconds.</summary>
        public static int Similarity(string left, string right)
        {
            if (string.IsNullOrEmpty(left) || string.IsNullOrEmpty(right)) return 0;
            if (left == right) return 100;

            var distance = new int[left.Length + 1, right.Length + 1];
            for (var i = 0; i <= left.Length; i++) distance[i, 0] = i;
            for (var j = 0; j <= right.Length; j++) distance[0, j] = j;

            for (var i = 1; i <= left.Length; i++)
            {
                for (var j = 1; j <= right.Length; j++)
                {
                    var cost = left[i - 1] == right[j - 1] ? 0 : 1;
                    distance[i, j] = Math.Min(Math.Min(distance[i - 1, j] + 1, distance[i, j - 1] + 1), distance[i - 1, j - 1] + cost);
                }
            }

            var longest = Math.Max(left.Length, right.Length);
            return (int)Math.Round((1.0 - (double)distance[left.Length, right.Length] / longest) * 100);
        }
    }
}
