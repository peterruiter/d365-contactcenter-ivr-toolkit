using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;
using Newtonsoft.Json;
using PowerPete.IvrToolkit.Common;

namespace PowerPete.IvrToolkit.Callback
{
    /// <summary>
    /// Hands a due callback to proactive engagement, which places the call.
    /// </summary>
    /// <remarks>
    /// Every reference to the CCaaS proactive engagement API lives in this file, for the
    /// same reason the platform metrics tables live only in QueueMetricsReader: it is not
    /// our contract, it moves in release waves, and a wave update should be a one file fix.
    ///
    /// The toolkit does not dial. Proactive engagement owns pacing, consent, quiet hours,
    /// representative capacity and answering machine detection, and reimplementing any of
    /// that would be both worse and a compliance problem. This class creates a delivery and
    /// stops.
    ///
    /// Until 3.5.0 promotion only set a status on our own table, which meant a scheduled
    /// callback was marked ready and then nothing read it. Proactive engagement takes its
    /// audience from a file upload, the CCaaS API, MCP or a Customer Insights journey. It
    /// cannot discover a custom table, so the API call is the missing link.
    /// </remarks>
    public class ProactiveDispatcher
    {
        // The API version is the CCaaS contract version, not ours. It is not a setting
        // because a caller cannot sensibly choose it: a different version is a different
        // parameter set, and this class would need changing anyway.
        private const string ApiVersion = "1.0";
        private const string Action = "CCaaS_CreateSimpleProactiveDelivery";

        private readonly IOrganizationService _service;
        private readonly ConfigReader _config;
        private readonly ITracingService _tracing;

        public ProactiveDispatcher(IOrganizationService service, ConfigReader config, ITracingService tracing)
        {
            _service = service;
            _config = config;
            _tracing = tracing;
        }

        public class DispatchResult
        {
            public bool Success;
            public string DeliveryId;
            public string Reason;
        }

        /// <summary>
        /// What proactive engagement made of a delivery, in this toolkit's vocabulary.
        /// </summary>
        public class DeliveryOutcome
        {
            /// <summary>Connected, NoAnswer, Cancelled, Failed, Dialling, or null while it waits.</summary>
            public string Outcome;
            public string Detail;
        }

        /// <summary>
        /// Reads the deliveries behind a set of callbacks and says what became of each.
        /// </summary>
        /// <remarks>
        /// The result vocabulary is theirs and the mapping belongs here with every other
        /// CCaaS detail. A delivery still Pending or InProcess returns Dialling or nothing,
        /// because a call that has not finished is not an outcome.
        ///
        /// CallFailed covers no answer, busy and a failed dial without distinguishing them,
        /// so it maps to NoAnswer rather than Failed. That is the retryable side of the
        /// choice, and ringing someone once more who asked to be rung is a smaller mistake
        /// than abandoning them because the first attempt hit a busy line.
        /// </remarks>
        public Dictionary<string, DeliveryOutcome> ReadOutcomes(ICollection<string> deliveryIds)
        {
            var outcomes = new Dictionary<string, DeliveryOutcome>();
            if (deliveryIds == null || deliveryIds.Count == 0) { return outcomes; }

            var query = new QueryExpression("msdyn_proactive_delivery")
            {
                ColumnSet = new ColumnSet("msdyn_delivery_id", "msdyn_status", "msdyn_result",
                    "msdyn_disposition_codes"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("msdyn_delivery_id", ConditionOperator.In,
                            deliveryIds.Cast<object>().ToArray())
                    }
                }
            };

            foreach (var delivery in _service.RetrieveMultiple(query).Entities)
            {
                var id = delivery.GetAttributeValue<string>("msdyn_delivery_id");
                if (string.IsNullOrWhiteSpace(id)) { continue; }

                var status = (delivery.GetAttributeValue<string>("msdyn_status") ?? string.Empty).Trim();
                var callResult = (delivery.GetAttributeValue<string>("msdyn_result") ?? string.Empty).Trim();
                var codes = delivery.GetAttributeValue<string>("msdyn_disposition_codes");

                string outcome = null;

                if (status.Equals("InProcess", StringComparison.OrdinalIgnoreCase))
                {
                    outcome = "Dialling";
                }
                else if (callResult.Equals("CallEnded", StringComparison.OrdinalIgnoreCase))
                {
                    outcome = "Connected";
                }
                else if (callResult.Equals("CallFailed", StringComparison.OrdinalIgnoreCase) ||
                         callResult.Equals("BotFailed", StringComparison.OrdinalIgnoreCase))
                {
                    outcome = "NoAnswer";
                }
                else if (callResult.Equals("Cancelled", StringComparison.OrdinalIgnoreCase) ||
                         status.Equals("Cancelled", StringComparison.OrdinalIgnoreCase))
                {
                    outcome = "Cancelled";
                }
                else if (callResult.Equals("Expired", StringComparison.OrdinalIgnoreCase) ||
                         callResult.Equals("Error", StringComparison.OrdinalIgnoreCase) ||
                         status.Equals("Expired", StringComparison.OrdinalIgnoreCase) ||
                         status.Equals("Error", StringComparison.OrdinalIgnoreCase))
                {
                    outcome = "Failed";
                }

                if (outcome == null) { continue; }

                var detail = string.IsNullOrWhiteSpace(callResult) ? status : callResult;
                if (!string.IsNullOrWhiteSpace(codes)) { detail = detail + " (" + codes + ")"; }

                outcomes[id] = new DeliveryOutcome { Outcome = outcome, Detail = detail };
            }

            return outcomes;
        }

        /// <summary>
        /// The proactive engagement configuration that will place the calls.
        /// </summary>
        /// <remarks>
        /// Derived from the outbound workstream rather than configured, because a proactive
        /// engagement is created from a workstream and carries it, so the id is already
        /// knowable from a setting that is picked off a list. Asking someone to open the
        /// table browser and copy a GUID for something the environment already knows is the
        /// same mistake as asking a speech IVR for a queue id.
        ///
        /// pwrp_ProactiveEngagementConfigId overrides it, for the environment running more
        /// than one engagement on one workstream. Ambiguity is refused rather than guessed
        /// at, the same way an ambiguous queue name is: choosing an engagement decides how
        /// customers are rung, and the wrong guess dials them in the wrong mode.
        /// </remarks>
        public string ResolveConfigId()
        {
            var configured = _config.GetString(ConfigKeys.ProactiveEngagementConfigId);
            if (!string.IsNullOrWhiteSpace(configured)) { return configured.Trim(); }

            var workstream = _config.GetString(ConfigKeys.OutboundWorkstreamId);
            Guid workstreamId;
            if (string.IsNullOrWhiteSpace(workstream) || !Guid.TryParse(workstream.Trim(), out workstreamId))
            {
                throw new ToolkitException(ErrorCodes.ConfigurationError,
                    "Set pwrp_OutboundWorkstreamId on the Settings page. Without it there is no " +
                    "way to find the proactive engagement that places scheduled callbacks.");
            }

            var query = new QueryExpression("msdyn_proactive_engagement_config")
            {
                ColumnSet = new ColumnSet("msdyn_name"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("statecode", ConditionOperator.Equal, 0),
                        new ConditionExpression("msdyn_workstream", ConditionOperator.Equal, workstreamId)
                    }
                },
                Orders = { new OrderExpression("msdyn_name", OrderType.Ascending) },
                // Five is enough to name them all in an error without reading a whole table
                // into a plugin to say "more than one".
                TopCount = 5
            };

            var found = _service.RetrieveMultiple(query).Entities;

            if (found.Count == 0)
            {
                throw new ToolkitException(ErrorCodes.ConfigurationError,
                    "No active proactive engagement is configured on the outbound workstream. " +
                    "Create one, or set pwrp_ProactiveEngagementConfigId.");
            }

            if (found.Count > 1)
            {
                var names = string.Join(", ", found.Select(f => f.GetAttributeValue<string>("msdyn_name")).ToArray());
                throw new ToolkitException(ErrorCodes.ConfigurationError,
                    "The outbound workstream has more than one active proactive engagement (" + names +
                    "). Set pwrp_ProactiveEngagementConfigId to the one that should place callbacks.");
            }

            var resolved = found[0];
            _tracing.Trace("[pwrp] dispatching through proactive engagement {0}",
                resolved.GetAttributeValue<string>("msdyn_name"));

            return resolved.Id.ToString();
        }

        /// <summary>
        /// Creates one delivery for a callback request. Never throws: a dispatch that fails
        /// comes back as a reason so the caller can leave the record for the next run rather
        /// than losing the whole batch to one bad number.
        /// </summary>
        public DispatchResult Dispatch(Entity callback, string configId, DateTime now)
        {
            var reference = callback.GetAttributeValue<string>("pwrp_name");

            try
            {
                var contactRef = callback.GetAttributeValue<EntityReference>("pwrp_contactid");
                if (contactRef == null)
                {
                    // Proactive engagement upserts on the identifier, so an invented one
                    // creates a contact. Silently manufacturing people from unmatched
                    // caller numbers is not a side effect a callback should have, so this
                    // stops instead. CreateCallback already matches on the number, and an
                    // operator can set the contact by hand and let the next run pick it up.
                    return Failed("No contact resolved, so there is no identifier to dispatch against.");
                }

                var contact = _service.Retrieve("contact", contactRef.Id,
                    new ColumnSet("firstname", "lastname", "mobilephone", "telephone1", "emailaddress1"));

                var request = new OrganizationRequest(Action);
                request["ApiVersion"] = ApiVersion;
                request["ProactiveEngagementConfigId"] = configId;
                request["UniqueIdentifier"] = contactRef.Id.ToString();

                // First and last name are required by the API. A contact with neither is
                // rare but real, and refusing the callback over a blank name would be
                // absurd, so the reference stands in and the representative sees it.
                request["FirstName"] = Coalesce(contact.GetAttributeValue<string>("firstname"), "Caller");
                request["LastName"] = Coalesce(contact.GetAttributeValue<string>("lastname"), reference);

                // The number the caller asked to be rung on wins over anything on the
                // contact record. They said it out loud, on this call, for this callback.
                request["MobilePhoneNumber"] = Coalesce(
                    callback.GetAttributeValue<string>("pwrp_phonenumber"),
                    contact.GetAttributeValue<string>("mobilephone"),
                    contact.GetAttributeValue<string>("telephone1"));

                var email = contact.GetAttributeValue<string>("emailaddress1");
                if (!string.IsNullOrWhiteSpace(email)) { request["Email"] = email; }

                request["Windows"] = BuildWindow(callback, now);
                request["InputAttributes"] = BuildInputAttributes(callback, reference);

                var response = _service.Execute(request);
                var deliveryId = ReadDeliveryId(response);

                if (deliveryId == null)
                {
                    // The response shape is undocumented and this is how it is learned.
                    // Treating an unreadable id as quietly fine turned a diagnosable state
                    // into an invisible one: a record at Queued with no id and no reason
                    // looks identical to a promotion that never called anything at all.
                    _tracing.Trace("[pwrp] dispatched {0}, no id found in response. Parameters: {1}",
                        reference,
                        response == null || response.Results == null
                            ? "(none)"
                            : string.Join(", ", response.Results.Keys.ToArray()));
                }
                else
                {
                    _tracing.Trace("[pwrp] dispatched callback {0} as delivery {1}", reference, deliveryId);
                }

                return new DispatchResult { Success = true, DeliveryId = deliveryId };
            }
            catch (Exception ex)
            {
                _tracing.Trace("[pwrp] dispatch of {0} failed: {1}", reference, ex.Message);
                return Failed(ex.Message);
            }
        }

        // How far ahead a window must open. The service rejects a start that is not "UTC
        // now or in the future", and a start of exactly now is in the past by the time the
        // request has been validated. This is transit time plus clock skew between the
        // sandbox and the proactive engagement service, not a deliberate delay.
        private const int WindowLeadMinutes = 2;

        /// <summary>
        /// One window, the booked slot. Without it the API assumes twenty four hours from
        /// now, which would let a nine o'clock callback be placed at four in the afternoon.
        /// </summary>
        private string BuildWindow(Entity callback, DateTime now)
        {
            var start = callback.GetAttributeValue<DateTime?>("pwrp_requestedstart") ?? now;
            var minutes = _config.GetInt(ConfigKeys.CallbackSlotMinutes, 30);

            // An overdue record has a window that closed before it was ever dispatched, and
            // a window in the past can never be called. Start from now in that case, which
            // is what a backlog draining after an outage needs. Now plus the lead, because
            // now itself is already the past by the time the service reads it.
            var earliest = now.AddMinutes(WindowLeadMinutes);
            if (start < earliest) { start = earliest; }

            var window = new[]
            {
                new Dictionary<string, string>
                {
                    { "Start", start.ToString("yyyy-MM-ddTHH:mm:ss") },
                    { "End", start.AddMinutes(minutes).ToString("yyyy-MM-ddTHH:mm:ss") }
                }
            };

            return JsonConvert.SerializeObject(window);
        }

        /// <summary>
        /// What the representative or the agent flow sees before the dial. The reference is
        /// first because it is what the caller was read out and the only thing they can
        /// quote back.
        /// </summary>
        private string BuildInputAttributes(Entity callback, string reference)
        {
            var attributes = new Dictionary<string, string>
            {
                { "CallbackReference", reference ?? string.Empty }
            };

            var queue = callback.GetAttributeValue<EntityReference>("pwrp_queueid");
            if (queue != null && !string.IsNullOrWhiteSpace(queue.Name))
            {
                attributes["Queue"] = queue.Name;
            }

            var locale = callback.GetAttributeValue<string>("pwrp_locale");
            if (!string.IsNullOrWhiteSpace(locale)) { attributes["Locale"] = locale; }

            var requested = callback.GetAttributeValue<DateTime?>("pwrp_requestedstart");
            if (requested.HasValue)
            {
                attributes["RequestedStartUtc"] = requested.Value.ToString("yyyy-MM-ddTHH:mm:ssZ");
            }

            // Whatever the agent gathered during the call. Passed through as a string
            // because InputAttributes is a flat map of strings, and flattening someone
            // else's JSON into it would collide with our own keys.
            var context = callback.GetAttributeValue<string>("pwrp_context");
            if (!string.IsNullOrWhiteSpace(context)) { attributes["Context"] = context; }

            return JsonConvert.SerializeObject(attributes);
        }

        /// <summary>
        /// The response shape is not documented, so this takes the first thing that looks
        /// like an identifier rather than assuming a parameter name. A delivery that was
        /// created but whose id we could not read is still a success: the call is placed
        /// either way, and only our own correlation suffers.
        /// </summary>
        private static string ReadDeliveryId(OrganizationResponse response)
        {
            if (response == null || response.Results == null) { return null; }

            foreach (var key in new[] { "DeliveryId", "deliveryId", "Id", "id" })
            {
                if (response.Results.Contains(key) && response.Results[key] != null)
                {
                    return response.Results[key].ToString();
                }
            }

            var first = response.Results.FirstOrDefault(r =>
                r.Key.IndexOf("delivery", StringComparison.OrdinalIgnoreCase) >= 0 && r.Value != null);

            return first.Value == null ? null : first.Value.ToString();
        }

        private static DispatchResult Failed(string reason)
        {
            return new DispatchResult { Success = false, Reason = reason };
        }

        private static string Coalesce(params string[] values)
        {
            return values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
        }
    }
}
