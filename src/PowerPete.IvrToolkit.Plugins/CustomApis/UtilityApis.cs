using System;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Queues;
using PowerPete.IvrToolkit.Speech;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;
using Newtonsoft.Json;

namespace PowerPete.IvrToolkit.CustomApis
{
    /// <summary>
    /// pwrp_ValidatePhoneNumber. Speech gives you dirty numbers. Clean before you write.
    /// Returns E.164 plus a digit-by-digit spelling so the agent can confirm it back.
    /// </summary>
    public class ValidatePhoneNumber : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            // Country, most specific first: an explicit CountryCode, then the queue's own,
            // then the organisation default. Queue is the one an agent should send, because
            // a market is a queue rather than a setting on the agent.
            // Normalised rather than read, so a placeholder typed into the tool
            // configuration falls through to the queue instead of becoming the dialling
            // prefix. See PhoneNumberValidator.NormaliseCountryCode.
            var country = PhoneNumberValidator.NormaliseCountryCode(request.GetString("CountryCode"));
            if (country == null)
            {
                var queueName = request.GetString("Queue");
                if (queueName != null)
                {
                    country = new QueueResolver(request.Service, request.Config, request.Tracing)
                        .Resolve(queueName).CountryCode;
                }
            }

            var raw = request.RequireString("PhoneNumber");
            var result = PhoneNumberValidator.Validate(
                raw,
                country ?? request.Config.GetString(ConfigKeys.DefaultCountryCode, "31"));

            request.SetOutput("IsValid", result.IsValid);
            request.SetOutput("E164", result.E164 ?? string.Empty);
            request.SetOutput("NumberType", result.NumberType);
            request.SetOutput("Reason", result.Reason ?? string.Empty);
            // Spelled back as the caller said it, not as it is stored. Someone who says
            // "0653740141" and hears "3 1 6 5 3 7 4 0 1 4 1" thinks a digit was missed.
            // E164 is what gets written; this is what gets verified.
            request.SetOutput("Speakable", SpeakableFormatter.SpellNumber(result.IsValid ? raw : null));
        }
    }

    /// <summary>
    /// pwrp_GetBroadcastMessage. An admin flips one record when there is an outage and the
    /// IVR reads it out. Cheap to build, and every client asks for it eventually.
    /// </summary>
    public class GetBroadcastMessage : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var queue = new QueueResolver(request.Service, request.Config, request.Tracing).Resolve(request.RequireString("Queue"));
            var message = BroadcastReader.Read(request.Service, queue.QueueId);

            request.SetOutput("HasMessage", !string.IsNullOrWhiteSpace(message));
            request.SetOutput("Speakable", message ?? string.Empty);
        }
    }

    internal static class BroadcastReader
    {
        /// <summary>
        /// Active broadcast for this queue, or an organisation-wide one. Queue specific wins.
        /// Short cache so an admin sees the change inside a minute.
        /// </summary>
        public static string Read(IOrganizationService service, Guid queueId)
        {
            return CacheStore.GetOrAdd($"broadcast:{queueId}", 30, () =>
            {
                var now = DateTime.UtcNow;

                var query = new QueryExpression("pwrp_broadcastmessage")
                {
                    ColumnSet = new ColumnSet("pwrp_message", "pwrp_queueid", "pwrp_validfrom", "pwrp_validto"),
                    Criteria =
                    {
                        Conditions =
                        {
                            new ConditionExpression("statecode", ConditionOperator.Equal, 0),
                            new ConditionExpression("pwrp_validfrom", ConditionOperator.OnOrBefore, now),
                            new ConditionExpression("pwrp_validto", ConditionOperator.OnOrAfter, now)
                        }
                    }
                };

                var rows = service.RetrieveMultiple(query).Entities
                    .Where(e =>
                    {
                        var reference = e.GetAttributeValue<EntityReference>("pwrp_queueid");
                        return reference == null || reference.Id == queueId;
                    })
                    .OrderByDescending(e => e.GetAttributeValue<EntityReference>("pwrp_queueid") != null)
                    .ToList();

                return rows.FirstOrDefault()?.GetAttributeValue<string>("pwrp_message");
            });
        }
    }

    /// <summary>
    /// pwrp_LogIvrOutcome. Write one row per IVR interaction so containment is measurable.
    ///
    /// Without this you cannot answer the only question the client will ask after go live:
    /// how many calls did the agent handle without a representative.
    /// </summary>
    public class LogIvrOutcome : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var record = new Entity("pwrp_ivroutcome")
            {
                ["pwrp_name"] = request.GetString("ConversationId", Guid.NewGuid().ToString()),
                ["pwrp_conversationid"] = request.GetString("ConversationId"),
                ["pwrp_outcome"] = request.RequireString("Outcome"),
                ["pwrp_intent"] = request.GetString("Intent"),
                ["pwrp_agentname"] = request.GetString("AgentName"),
                ["pwrp_durationseconds"] = request.GetInt("DurationSeconds", 0),
                ["pwrp_contextjson"] = request.GetString("ContextJson"),
                ["pwrp_occurredon"] = DateTime.UtcNow
            };

            var queueRaw = request.GetString("Queue");
            if (!string.IsNullOrWhiteSpace(queueRaw))
            {
                try
                {
                    var queue = new QueueResolver(request.Service, request.Config, request.Tracing).Resolve(queueRaw);
                    record["pwrp_queueid"] = new EntityReference("queue", queue.QueueId);
                }
                catch (ToolkitException)
                {
                    // Logging must never fail the call. An unresolvable queue is recorded as text.
                    record["pwrp_queuetext"] = queueRaw;
                }
            }

            request.SetOutput("OutcomeId", request.Service.Create(record).ToString());
        }
    }

    /// <summary>
    /// pwrp_HealthCheck. Run after install and after every upgrade.
    ///
    /// Validates the things that silently break a deployment: missing queue profiles,
    /// queues with no hours, metrics tables that no longer match, callback config that is
    /// half done. Saves days of support on a reusable product.
    /// </summary>
    public class HealthCheck : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var checks = new System.Collections.Generic.List<object>();
            var resolver = new QueueResolver(request.Service, request.Config, request.Tracing);
            var queues = resolver.ListQueues(null);
            var failures = 0;

            void Add(string name, bool passed, string detail)
            {
                if (!passed) failures++;
                checks.Add(new { Check = name, Passed = passed, Detail = detail });
            }

            Add("Queues discovered", queues.Count > 0, $"{queues.Count} active queues found.");

            // Voice only. An organisation can have hundreds of entity and messaging queues
            // that no IVR will ever route to, and demanding a profile on those turns this
            // check into noise that gets ignored, which is worse than not checking.
            var voice = queues.Where(q => string.Equals(q.ChannelType, "Voice", StringComparison.OrdinalIgnoreCase)).ToList();
            var withProfile = voice.Count(q => q.ProfileId.HasValue);
            Add("Queue profiles", voice.Count == 0 || withProfile == voice.Count,
                $"{withProfile} of {voice.Count} voice queues have a pwrp_queueprofile row. " +
                $"{queues.Count - voice.Count} non voice queues ignored.");

            Add("Metrics schema", TableExists(request.Service, "msdyn_queueextension"),
                "msdyn_queueextension is readable. This table is internal to the platform and carries no API guarantee.");

            Add("Presence schema", TableExists(request.Service, "msdyn_agentstatushistory"),
                "msdyn_agentstatushistory is readable.");

            var scheduled = request.Config.GetBool(ConfigKeys.EnableScheduledCallback, false);
            var workstream = request.Config.GetString(ConfigKeys.OutboundWorkstreamId);
            Add("Scheduled callback config", !scheduled || !string.IsNullOrWhiteSpace(workstream),
                scheduled
                    ? "Scheduled callback is on. pwrp_OutboundWorkstreamId must point at an outbound workstream."
                    : "Scheduled callback is off.");

            // Config being right proves nothing about anything running. Scheduled callback
            // needs a recurrence flow calling pwrp_PromoteDueCallbacks, and that flow is not
            // part of the solution, so the ordinary way for this feature to fail is that
            // nobody built it. Records then sit at Requested for ever and the only person
            // who finds out is the caller who was never rung.
            if (scheduled)
            {
                var overdue = new QueryExpression("pwrp_callbackrequest")
                {
                    ColumnSet = new ColumnSet("pwrp_callbackrequestid"),
                    TopCount = 50,
                    Criteria =
                    {
                        Conditions =
                        {
                            new ConditionExpression("pwrp_status", ConditionOperator.Equal, 1),
                            new ConditionExpression("pwrp_requestedstart", ConditionOperator.OnOrBefore,
                                DateTime.UtcNow.AddMinutes(-15))
                        }
                    }
                };

                var stuck = request.Service.RetrieveMultiple(overdue).Entities.Count;
                Add("Callback promotion", stuck == 0,
                    stuck == 0
                        ? "No scheduled callback is overdue. Whatever promotes them is running."
                        : $"{stuck} scheduled callbacks are more than 15 minutes past their time and still Requested. " +
                          "Nothing is calling pwrp_PromoteDueCallbacks. Build the recurrence flow.");
            }

            Add("Default locale", !string.IsNullOrWhiteSpace(request.Config.GetString(ConfigKeys.DefaultLocale)),
                $"pwrp_DefaultLocale = {request.Config.GetString(ConfigKeys.DefaultLocale, "not set")}");

            request.SetOutput("Checks", JsonConvert.SerializeObject(checks));
            request.SetOutput("Passed", failures == 0);
            request.SetOutput("FailureCount", failures);
        }

        private static bool TableExists(IOrganizationService service, string logicalName)
        {
            try
            {
                service.RetrieveMultiple(new QueryExpression(logicalName)
                {
                    ColumnSet = new ColumnSet(false),
                    TopCount = 1
                });
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }
}
