using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Model;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace PowerPete.IvrToolkit.Metrics
{
    /// <summary>
    /// Live queue state.
    ///
    /// SUPPORT NOTE: there is no supported public API for real-time contact centre metrics.
    /// The real-time dashboards query msdyn_queueextension and msdyn_ocliveworkitem directly,
    /// so that is what this reader does. Those tables carry no API guarantee and the schema
    /// has moved between waves. Everything that touches them lives in this one file so a
    /// break is a single-file fix. If the reader throws, the toolkit returns
    /// METRICS_UNAVAILABLE and the agent falls back to a generic wait message rather than
    /// failing the call.
    /// </summary>
    public class QueueMetricsReader
    {
        private const int OpenConversationStatus = 1;

        private readonly IOrganizationService _service;
        private readonly ConfigReader _config;
        private readonly ITracingService _tracing;

        public QueueMetricsReader(IOrganizationService service, ConfigReader config, ITracingService tracing)
        {
            _service = service;
            _config = config;
            _tracing = tracing;
        }

        public QueueMetrics Read(QueueRef queue)
        {
            var ttl = _config.GetInt(ConfigKeys.MetricsCacheSeconds, 15);

            return CacheStore.GetOrAdd($"metrics:{queue.QueueId}", ttl, () =>
            {
                var metrics = new QueueMetrics { AsOfUtc = DateTime.UtcNow };

                try
                {
                    ReadWaiting(queue.QueueId, metrics);
                    ReadTrailingAverage(queue.QueueId, metrics);
                    ReadAvailability(queue.QueueId, metrics);
                    Estimate(metrics);
                    metrics.WaitBand = WaitBandCalculator.Band(metrics.EstimatedWaitSeconds ?? metrics.LongestWaitSeconds,
                        _config.GetString(ConfigKeys.WaitBandThresholds, "60,180,420"));
                }
                catch (Exception ex)
                {
                    _tracing.Trace("[pwrp] metrics read failed: {0}", ex);
                    throw new ToolkitException(ErrorCodes.MetricsUnavailable,
                        "Live queue metrics are not available right now.");
                }

                return metrics;
            });
        }

        /// <summary>
        /// Segments waiting now, and the longest of them.
        /// A segment is open when msdyn_endtime is null, the parent conversation is open,
        /// and the conversation is inbound.
        /// </summary>
        private void ReadWaiting(Guid queueId, QueueMetrics metrics)
        {
            var query = new QueryExpression("msdyn_queueextension")
            {
                ColumnSet = new ColumnSet("msdyn_waitstartedon", "msdyn_starttime"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("msdyn_queue", ConditionOperator.Equal, queueId),
                        new ConditionExpression("msdyn_endtime", ConditionOperator.Null)
                    }
                }
            };

            var conversation = query.AddLink("msdyn_ocliveworkitem", "msdyn_liveworkitemid", "msdyn_ocliveworkitemid");
            conversation.EntityAlias = "c";
            conversation.LinkCriteria.AddCondition("statuscode", ConditionOperator.Equal, OpenConversationStatus);
            conversation.LinkCriteria.AddCondition("msdyn_isoutbound", ConditionOperator.Equal, false);

            var rows = _service.RetrieveMultiple(query).Entities;
            metrics.WaitingNow = rows.Count;

            var now = DateTime.UtcNow;
            var waits = rows
                .Select(r => r.GetAttributeValue<DateTime?>("msdyn_waitstartedon") ?? r.GetAttributeValue<DateTime?>("msdyn_starttime"))
                .Where(t => t.HasValue)
                .Select(t => (int)(now - t.Value).TotalSeconds)
                .Where(s => s >= 0)
                .ToList();

            metrics.LongestWaitSeconds = waits.Count > 0 ? waits.Max() : 0;
        }

        /// <summary>
        /// Average first wait over a trailing window. This is the number that predicts,
        /// where longest wait only describes.
        /// </summary>
        private void ReadTrailingAverage(Guid queueId, QueueMetrics metrics)
        {
            var windowMinutes = _config.GetInt(ConfigKeys.MetricsWindowMinutes, 60);

            var query = new QueryExpression("msdyn_queueextension")
            {
                ColumnSet = new ColumnSet("msdyn_firstwaittimeinseconds"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("msdyn_queue", ConditionOperator.Equal, queueId),
                        new ConditionExpression("msdyn_agentacceptedon", ConditionOperator.NotNull),
                        new ConditionExpression("msdyn_agentacceptedon", ConditionOperator.OnOrAfter, DateTime.UtcNow.AddMinutes(-windowMinutes))
                    }
                }
            };

            var values = _service.RetrieveMultiple(query).Entities
                .Select(e => e.GetAttributeValue<int?>("msdyn_firstwaittimeinseconds"))
                .Where(v => v.HasValue)
                .Select(v => v.Value)
                .ToList();

            metrics.AverageWaitSeconds = values.Count > 0 ? (int)values.Average() : 0;
            metrics.IsStale = values.Count == 0;
        }

        /// <summary>
        /// Representatives online is a weak signal on its own. What matters is how many
        /// members of this queue are in an Available presence with capacity left, so both
        /// numbers are returned and the estimate uses the available one.
        /// </summary>
        private void ReadAvailability(Guid queueId, QueueMetrics metrics)
        {
            var members = LoadQueueMembers(queueId);
            if (members.Count == 0)
            {
                return;
            }

            var query = new QueryExpression("msdyn_agentstatushistory")
            {
                ColumnSet = new ColumnSet("msdyn_agentid", "msdyn_presenceid"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("msdyn_endtime", ConditionOperator.Null),
                        new ConditionExpression("msdyn_agentid", ConditionOperator.In, members.Cast<object>().ToArray())
                    }
                }
            };

            var presence = query.AddLink("msdyn_presence", "msdyn_presenceid", "msdyn_presenceid", JoinOperator.LeftOuter);
            presence.EntityAlias = "p";
            presence.Columns = new ColumnSet("msdyn_basepresencestatus", "msdyn_presencetext");

            var rows = _service.RetrieveMultiple(query).Entities;
            metrics.RepresentativesOnline = rows.Count;

            metrics.RepresentativesAvailable = rows.Count(r =>
            {
                if (!r.Contains("p.msdyn_basepresencestatus") || !(r["p.msdyn_basepresencestatus"] is AliasedValue aliased))
                {
                    return false;
                }
                // 192350000 = Available in the base presence option set.
                return (aliased.Value as OptionSetValue)?.Value == 192350000;
            });

            metrics.AvailableCapacityUnits = metrics.RepresentativesAvailable;
        }

        private List<Guid> LoadQueueMembers(Guid queueId)
        {
            var query = new QueryExpression("systemuser")
            {
                ColumnSet = new ColumnSet("systemuserid"),
                Criteria = { Conditions = { new ConditionExpression("isdisabled", ConditionOperator.Equal, false) } }
            };

            var membership = query.AddLink("queuemembership", "systemuserid", "systemuserid");
            membership.LinkCriteria.AddCondition("queueid", ConditionOperator.Equal, queueId);

            return _service.RetrieveMultiple(query).Entities
                .Select(e => e.GetAttributeValue<Guid>("systemuserid"))
                .ToList();
        }

        /// <summary>
        /// Estimated wait: position in queue divided by available representatives, times
        /// the trailing average handle interval. Falls back to the trailing average when
        /// there is nobody available, because dividing by zero on a live call is a bad look.
        /// </summary>
        private static void Estimate(QueueMetrics metrics)
        {
            if (metrics.WaitingNow == 0)
            {
                metrics.EstimatedWaitSeconds = 0;
                return;
            }

            if (metrics.RepresentativesAvailable <= 0)
            {
                metrics.EstimatedWaitSeconds = Math.Max(metrics.AverageWaitSeconds, metrics.LongestWaitSeconds);
                return;
            }

            var perCaller = metrics.AverageWaitSeconds > 0 ? metrics.AverageWaitSeconds : 120;
            metrics.EstimatedWaitSeconds = (int)Math.Ceiling((double)metrics.WaitingNow / metrics.RepresentativesAvailable * perCaller);
        }
    }
}
