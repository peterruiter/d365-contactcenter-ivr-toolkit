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
        /// True when the environment is configured well enough to dispatch anything.
        /// </summary>
        public bool IsConfigured
        {
            get { return !string.IsNullOrWhiteSpace(_config.GetString(ConfigKeys.ProactiveEngagementConfigId)); }
        }

        /// <summary>
        /// Creates one delivery for a callback request. Never throws: a dispatch that fails
        /// comes back as a reason so the caller can leave the record for the next run rather
        /// than losing the whole batch to one bad number.
        /// </summary>
        public DispatchResult Dispatch(Entity callback, DateTime now)
        {
            var reference = callback.GetAttributeValue<string>("pwrp_name");

            try
            {
                var configId = _config.GetString(ConfigKeys.ProactiveEngagementConfigId);
                if (string.IsNullOrWhiteSpace(configId))
                {
                    return Failed("pwrp_ProactiveEngagementConfigId is not set.");
                }

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

                _tracing.Trace("[pwrp] dispatched callback {0} as delivery {1}", reference, deliveryId ?? "(no id)");
                return new DispatchResult { Success = true, DeliveryId = deliveryId };
            }
            catch (Exception ex)
            {
                _tracing.Trace("[pwrp] dispatch of {0} failed: {1}", reference, ex.Message);
                return Failed(ex.Message);
            }
        }

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
            // is what a backlog draining after an outage needs.
            if (start < now) { start = now; }

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
