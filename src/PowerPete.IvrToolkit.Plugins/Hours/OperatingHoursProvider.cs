using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Model;
using PowerPete.IvrToolkit.Speech;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace PowerPete.IvrToolkit.Hours
{
    /// <summary>
    /// Reads the native operating hours calendar.
    ///
    /// SUPPORT NOTE: msdyn_operatinghour points at a calendar record whose calendarrule
    /// rows carry the recurrence. This model is internal to the platform and has changed
    /// shape between release waves. If a wave update breaks this provider, switch the
    /// affected queue profiles to the Config provider and raise an issue. Nothing else
    /// in the toolkit depends on this file.
    /// </summary>
    public class OperatingHoursProvider : IHoursProvider
    {
        private readonly IOrganizationService _service;
        private readonly ITracingService _tracing;

        public OperatingHoursProvider(IOrganizationService service, ITracingService tracing)
        {
            _service = service;
            _tracing = tracing;
        }

        public List<DayHours> GetHours(QueueRef queue, DateTime fromLocal, int days)
        {
            var calendarId = FindCalendar(queue.QueueId);
            if (calendarId == null)
            {
                throw new ToolkitException(ErrorCodes.HoursNotConfigured,
                    "No operating hours are linked to this queue. Link operating hours in the admin centre, or switch the queue profile to config hours.");
            }

            var rules = LoadRules(calendarId.Value);
            var result = new List<DayHours>();

            for (var offset = 0; offset < days; offset++)
            {
                var date = fromLocal.Date.AddDays(offset);
                var day = new DayHours { Date = date, DayOfWeek = date.DayOfWeek.ToString() };

                var closures = rules.Where(r => r.IsClosure && r.Covers(date)).ToList();
                if (closures.Any())
                {
                    day.IsOpen = false;
                    day.Speakable = SpeakableFormatter.DescribeDay(day, queue.Locale);
                    result.Add(day);
                    continue;
                }

                day.Windows = rules
                    .Where(r => !r.IsClosure && r.AppliesOn(date))
                    .Select(r => new OpeningWindow { StartLocal = date.Add(r.Start), EndLocal = date.Add(r.Start).AddMinutes(r.DurationMinutes) })
                    .OrderBy(w => w.StartLocal)
                    .ToList();

                day.IsOpen = day.Windows.Count > 0;
                day.Speakable = SpeakableFormatter.DescribeDay(day, queue.Locale);
                result.Add(day);
            }

            return result;
        }

        private Guid? FindCalendar(Guid queueId)
        {
            var query = new QueryExpression("msdyn_operatinghour")
            {
                ColumnSet = new ColumnSet("msdyn_calendarid"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("pwrp_relatedqueueid", ConditionOperator.Equal, queueId)
                    }
                },
                TopCount = 1
            };

            // Queues expose operating hours through a lookup added by the Contact Center solution.
            // The setup script maps that lookup name into pwrp_relatedqueueid on install so this
            // query stays stable when the platform renames the relationship.
            var found = _service.RetrieveMultiple(query).Entities.FirstOrDefault();
            return found?.GetAttributeValue<EntityReference>("msdyn_calendarid")?.Id;
        }

        private class Rule
        {
            public TimeSpan Start;
            public int DurationMinutes;
            public bool IsClosure;
            public DateTime? EffectiveFrom;
            public DateTime? EffectiveTo;
            public HashSet<DayOfWeek> Days = new HashSet<DayOfWeek>();

            public bool AppliesOn(DateTime date)
            {
                if (EffectiveFrom.HasValue && date < EffectiveFrom.Value.Date) return false;
                if (EffectiveTo.HasValue && date > EffectiveTo.Value.Date) return false;
                return Days.Count == 0 || Days.Contains(date.DayOfWeek);
            }

            public bool Covers(DateTime date)
            {
                return EffectiveFrom.HasValue && EffectiveTo.HasValue
                       && date >= EffectiveFrom.Value.Date && date <= EffectiveTo.Value.Date;
            }
        }

        private List<Rule> LoadRules(Guid calendarId)
        {
            var query = new QueryExpression("calendarrule")
            {
                ColumnSet = new ColumnSet("starttime", "duration", "pattern", "effectiveintervalstart", "effectiveintervalend", "innercalendarid", "timezonecode"),
                Criteria = { Conditions = { new ConditionExpression("calendarid", ConditionOperator.Equal, calendarId) } }
            };

            var rules = new List<Rule>();
            foreach (var row in _service.RetrieveMultiple(query).Entities)
            {
                var rule = new Rule
                {
                    Start = row.GetAttributeValue<DateTime>("starttime").TimeOfDay,
                    DurationMinutes = row.GetAttributeValue<int>("duration"),
                    EffectiveFrom = row.GetAttributeValue<DateTime?>("effectiveintervalstart"),
                    EffectiveTo = row.GetAttributeValue<DateTime?>("effectiveintervalend")
                };

                var pattern = row.GetAttributeValue<string>("pattern") ?? string.Empty;
                rule.IsClosure = rule.DurationMinutes == 0;

                foreach (var token in ParseByDay(pattern))
                {
                    rule.Days.Add(token);
                }

                rules.Add(rule);
            }

            _tracing.Trace("[pwrp] loaded {0} calendar rules", rules.Count);
            return rules;
        }

        private static IEnumerable<DayOfWeek> ParseByDay(string pattern)
        {
            var marker = pattern.IndexOf("BYDAY=", StringComparison.OrdinalIgnoreCase);
            if (marker < 0) yield break;

            var segment = pattern.Substring(marker + 6).Split(';')[0];
            foreach (var token in segment.Split(','))
            {
                switch (token.Trim().ToUpperInvariant())
                {
                    case "MO": yield return DayOfWeek.Monday; break;
                    case "TU": yield return DayOfWeek.Tuesday; break;
                    case "WE": yield return DayOfWeek.Wednesday; break;
                    case "TH": yield return DayOfWeek.Thursday; break;
                    case "FR": yield return DayOfWeek.Friday; break;
                    case "SA": yield return DayOfWeek.Saturday; break;
                    case "SU": yield return DayOfWeek.Sunday; break;
                }
            }
        }
    }
}
