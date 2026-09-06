using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace PowerPete.IvrToolkit.Callback
{
    /// <summary>
    /// Moves scheduled callbacks from Requested to Queued when they come due, and applies
    /// the retry policy to attempts that did not connect.
    ///
    /// The logic lives here rather than in the cloud flow on purpose. A flow with branching,
    /// date maths and a retry policy inside it is unreviewable and untestable. The flow
    /// stays a timer that calls one action.
    /// </summary>
    public class CallbackScheduler
    {
        private const int StatusRequested = 1;
        private const int StatusQueued = 2;
        private const int StatusDialling = 3;
        private const int StatusCompleted = 4;
        private const int StatusCancelled = 5;
        private const int StatusFailed = 6;
        private const int StatusNoAnswer = 7;

        private readonly IOrganizationService _service;
        private readonly ConfigReader _config;
        private readonly ITracingService _tracing;

        public CallbackScheduler(IOrganizationService service, ConfigReader config, ITracingService tracing)
        {
            _service = service;
            _config = config;
            _tracing = tracing;
        }

        public class PromotionResult
        {
            public int Promoted;
            public int Retried;
            public int Failed;
            public int Expired;
            public int Reconciled;
            public List<string> References = new List<string>();
        }

        /// <summary>
        /// Called by the Power Pete Promote Due Callbacks flow every five minutes.
        /// Idempotent. A double run promotes nothing twice, because promotion is a status
        /// transition and the query only ever picks up Requested rows.
        /// </summary>
        public PromotionResult PromoteDue(int lookAheadMinutes)
        {
            var result = new PromotionResult();

            if (!_config.GetBool(ConfigKeys.EnableScheduledCallback, false))
            {
                _tracing.Trace("[pwrp] scheduled callback disabled, nothing to promote");
                return result;
            }

            // Resolved once for the batch, and deliberately outside the per record try:
            // a misconfigured engagement is not a bad record, and marking a hundred
            // callbacks failed over one missing setting would be wrong.
            var dispatcher = new ProactiveDispatcher(_service, _config, _tracing);
            var configId = dispatcher.ResolveConfigId();

            var workstream = _config.GetString(ConfigKeys.OutboundWorkstreamId);
            var now = DateTime.UtcNow;
            var horizon = now.AddMinutes(lookAheadMinutes);

            foreach (var record in DueRequests(horizon))
            {
                var reference = record.GetAttributeValue<string>("pwrp_name");
                var dispatch = dispatcher.Dispatch(record, configId, now);

                if (!dispatch.Success)
                {
                    // Left at Requested deliberately, so the next run retries it. A
                    // transient outage would otherwise fail a whole backlog permanently,
                    // and a record that is genuinely undispatchable is not lost either:
                    // ExpireStale gives up on it after 24 hours and says why.
                    _service.Update(new Entity("pwrp_callbackrequest", record.Id)
                    {
                        ["pwrp_failurereason"] = Truncate(dispatch.Reason, 400)
                    });

                    result.Failed++;
                    continue;
                }

                // Queued means handed over, not dialled. Proactive engagement decides when
                // the call is placed inside the window, and RecordOutcome moves it on.
                var update = new Entity("pwrp_callbackrequest", record.Id)
                {
                    ["pwrp_status"] = new OptionSetValue(StatusQueued),
                    ["pwrp_queuedon"] = now,
                    ["pwrp_deliveryid"] = dispatch.DeliveryId,
                    ["pwrp_failurereason"] = null
                };
                if (!string.IsNullOrWhiteSpace(workstream)) { update["pwrp_workstreamid"] = workstream; }
                _service.Update(update);

                result.Promoted++;
                result.References.Add(reference);
                _tracing.Trace("[pwrp] promoted callback {0}", reference);
            }

            // Before the retry policy, because reconciliation is what produces the NoAnswer
            // records the retry policy acts on. The other order would always work a cycle
            // behind.
            Reconcile(dispatcher, result);
            ApplyRetryPolicy(now, result);
            ExpireStale(now, result);

            return result;
        }

        private static string Truncate(string value, int max)
        {
            if (string.IsNullOrEmpty(value)) { return value; }
            return value.Length <= max ? value : value.Substring(0, max);
        }

        private IEnumerable<Entity> DueRequests(DateTime horizon)
        {
            var query = new QueryExpression("pwrp_callbackrequest")
            {
                ColumnSet = new ColumnSet("pwrp_name", "pwrp_queueid", "pwrp_requestedstart", "pwrp_mode",
                    "pwrp_contactid", "pwrp_phonenumber", "pwrp_locale", "pwrp_context"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("pwrp_status", ConditionOperator.Equal, StatusRequested),
                        new ConditionExpression("pwrp_requestedstart", ConditionOperator.OnOrBefore, horizon)
                    }
                },
                Orders = { new OrderExpression("pwrp_requestedstart", OrderType.Ascending) },
                // Cap the batch. A backlog drains over several runs rather than
                // dumping two hundred calls into a queue at once.
                TopCount = 100
            };

            return _service.RetrieveMultiple(query).Entities;
        }

        /// <summary>
        /// Asks proactive engagement what became of the callbacks it was handed, and moves
        /// them on.
        /// </summary>
        /// <remarks>
        /// Queued means handed over, and nothing was closing the loop: a callback that was
        /// placed and answered stayed at Queued for ever, ExpireStale eventually marked it
        /// failed 24 hours later, and the record then said a call that happened had not.
        /// The retry policy was dead for the same reason, because nothing ever set NoAnswer.
        ///
        /// Done here rather than in a second flow triggered on the delivery table. This
        /// timer already runs every five minutes, the delivery id gives an exact join, and
        /// a component that has to be installed and have a connection bound is a component
        /// that gets skipped. RecordOutcome stays for anything that wants to report an
        /// outcome directly and sooner.
        /// </remarks>
        private void Reconcile(ProactiveDispatcher dispatcher, PromotionResult result)
        {
            var query = new QueryExpression("pwrp_callbackrequest")
            {
                ColumnSet = new ColumnSet("pwrp_name", "pwrp_deliveryid"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("pwrp_status", ConditionOperator.In, StatusQueued, StatusDialling),
                        new ConditionExpression("pwrp_deliveryid", ConditionOperator.NotNull)
                    }
                },
                TopCount = 200
            };

            var waiting = _service.RetrieveMultiple(query).Entities;
            if (waiting.Count == 0) { return; }

            var byDelivery = new Dictionary<string, Entity>();
            foreach (var record in waiting)
            {
                var id = record.GetAttributeValue<string>("pwrp_deliveryid");
                if (!string.IsNullOrWhiteSpace(id)) { byDelivery[id] = record; }
            }

            Dictionary<string, ProactiveDispatcher.DeliveryOutcome> outcomes;
            try
            {
                outcomes = dispatcher.ReadOutcomes(byDelivery.Keys);
            }
            catch (Exception ex)
            {
                // The delivery table is theirs and carries no API guarantee, so a schema
                // change here must not stop callbacks being promoted. Same rule as the
                // metrics reader: reporting degrades, dispatch does not.
                _tracing.Trace("[pwrp] could not read deliveries, skipping reconciliation: {0}", ex.Message);
                return;
            }

            foreach (var pair in outcomes)
            {
                var record = byDelivery[pair.Key];
                var reference = record.GetAttributeValue<string>("pwrp_name");

                RecordOutcome(record.Id, pair.Value.Outcome, pair.Value.Detail);
                result.Reconciled++;
                _tracing.Trace("[pwrp] callback {0} is {1}", reference, pair.Value.Outcome);
            }
        }

        /// <summary>
        /// A dial that did not connect comes back as NoAnswer. Retry it after the configured
        /// gap until the attempt cap, then mark it Failed.
        /// </summary>
        private void ApplyRetryPolicy(DateTime now, PromotionResult result)
        {
            var maxAttempts = _config.GetInt(ConfigKeys.MaxCallbackAttempts, 3);
            var gapMinutes = _config.GetInt(ConfigKeys.CallbackRetryMinutes, 20);

            var query = new QueryExpression("pwrp_callbackrequest")
            {
                ColumnSet = new ColumnSet("pwrp_name", "pwrp_attempts", "pwrp_lastattemptedon"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("pwrp_status", ConditionOperator.Equal, StatusNoAnswer),
                        new ConditionExpression("pwrp_lastattemptedon", ConditionOperator.OnOrBefore, now.AddMinutes(-gapMinutes))
                    }
                },
                TopCount = 100
            };

            foreach (var record in _service.RetrieveMultiple(query).Entities)
            {
                var attempts = record.GetAttributeValue<int>("pwrp_attempts");

                if (attempts >= maxAttempts)
                {
                    _service.Update(new Entity("pwrp_callbackrequest", record.Id)
                    {
                        ["pwrp_status"] = new OptionSetValue(StatusFailed),
                        ["pwrp_failurereason"] = $"No answer after {attempts} attempts."
                    });
                    result.Failed++;
                    continue;
                }

                _service.Update(new Entity("pwrp_callbackrequest", record.Id)
                {
                    ["pwrp_status"] = new OptionSetValue(StatusRequested),
                    ["pwrp_requestedstart"] = now
                });
                result.Retried++;
            }
        }

        /// <summary>
        /// A callback nobody dialled within 24 hours of its slot is not worth placing.
        /// Calling someone a day late about a wait they had yesterday annoys them.
        /// </summary>
        private void ExpireStale(DateTime now, PromotionResult result)
        {
            var query = new QueryExpression("pwrp_callbackrequest")
            {
                ColumnSet = new ColumnSet("pwrp_name", "pwrp_status"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("pwrp_status", ConditionOperator.In, StatusRequested, StatusQueued),
                        new ConditionExpression("pwrp_requestedstart", ConditionOperator.OnOrBefore, now.AddHours(-24))
                    }
                },
                TopCount = 200
            };

            foreach (var record in _service.RetrieveMultiple(query).Entities)
            {
                // Two different failures, and saying the wrong one sends whoever reads the
                // record to the wrong place. Still Requested means nothing dispatched it.
                // Queued means it was handed over and proactive engagement never reported
                // back, which is a question for the engagement, not for promotion.
                var wasQueued = record.GetAttributeValue<OptionSetValue>("pwrp_status") != null &&
                                record.GetAttributeValue<OptionSetValue>("pwrp_status").Value == StatusQueued;

                _service.Update(new Entity("pwrp_callbackrequest", record.Id)
                {
                    ["pwrp_status"] = new OptionSetValue(StatusFailed),
                    ["pwrp_failurereason"] = wasQueued
                        ? "Expired. Dispatched, but proactive engagement reported no outcome within 24 hours."
                        : "Expired. Not dispatched within 24 hours of the requested time."
                });
                result.Expired++;
            }
        }

        /// <summary>
        /// Called from proactive engagement once a dial finishes, so the retry policy has
        /// something to act on. Without this every callback sits in Dialling forever.
        /// </summary>
        public string RecordOutcome(Guid callbackId, string outcome, string detail)
        {
            int status;
            switch ((outcome ?? string.Empty).ToLowerInvariant())
            {
                case "connected":
                case "completed": status = StatusCompleted; break;
                case "noanswer":
                case "voicemail": status = StatusNoAnswer; break;
                case "dialling":
                case "dialing": status = StatusDialling; break;
                case "cancelled": status = StatusCancelled; break;
                case "failed": status = StatusFailed; break;
                default:
                    throw new ToolkitException(ErrorCodes.InvalidInput,
                        "Outcome must be Connected, NoAnswer, Voicemail, Dialling, Cancelled or Failed.");
            }

            var current = _service.Retrieve("pwrp_callbackrequest", callbackId, new ColumnSet("pwrp_attempts"));
            var attempts = current.GetAttributeValue<int>("pwrp_attempts");

            var update = new Entity("pwrp_callbackrequest", callbackId)
            {
                ["pwrp_status"] = new OptionSetValue(status),
                ["pwrp_lastattemptedon"] = DateTime.UtcNow,
                ["pwrp_failurereason"] = detail
            };

            // Only a real dial counts as an attempt. A status sync does not.
            if (status == StatusNoAnswer || status == StatusCompleted)
            {
                update["pwrp_attempts"] = attempts + 1;
            }

            if (status == StatusCompleted)
            {
                update["pwrp_completedon"] = DateTime.UtcNow;
            }

            _service.Update(update);
            return status == StatusCompleted ? "Completed" : status == StatusNoAnswer ? "NoAnswer" : outcome;
        }
    }
}
