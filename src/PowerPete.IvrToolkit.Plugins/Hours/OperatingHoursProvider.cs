using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Model;
using PowerPete.IvrToolkit.Speech;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Messages;
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

        /// <summary>
        /// Walks queue to operating hours to calendar.
        /// </summary>
        /// <remarks>
        /// Confirmed against a real environment, 2026-09-04:
        ///   queue.msdyn_operatinghourid   Lookup to msdyn_operatinghour
        ///   msdyn_operatinghour.msdyn_calendarid   String, not a lookup, holding a GUID
        /// There is no queue lookup on msdyn_operatinghour, so this has to start at the
        /// queue and read forwards. The calendar id being text is the surprise: reading it
        /// as an EntityReference throws rather than returning null.
        /// </remarks>
        private Guid? FindCalendar(Guid queueId)
        {
            var queue = _service.Retrieve("queue", queueId, new ColumnSet("msdyn_operatinghourid"));
            var operatingHours = queue.GetAttributeValue<EntityReference>("msdyn_operatinghourid");
            if (operatingHours == null)
            {
                return null;
            }

            var hours = _service.Retrieve("msdyn_operatinghour", operatingHours.Id, new ColumnSet("msdyn_calendarid"));
            var calendarId = hours.GetAttributeValue<string>("msdyn_calendarid");

            Guid parsed;
            return Guid.TryParse(calendarId, out parsed) ? parsed : (Guid?)null;
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

        /// <summary>
        /// Loads the recurrence rules for a calendar.
        /// </summary>
        /// <remarks>
        /// Confirmed against a real environment, 2026-09-04: calendarrule cannot be queried
        /// directly. RetrieveMultiple on it fails with "does not support entities of type
        /// calendarrule", so the rules come back as a related collection on the calendar
        /// through the calendar_calendar_rules relationship instead.
        ///
        /// A pattern looks like FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR, and duration is
        /// in minutes.
        /// </remarks>
        private List<Entity> LoadCalendarRules(Guid calendarId)
        {
            var request = new RetrieveRequest
            {
                Target = new EntityReference("calendar", calendarId),
                ColumnSet = new ColumnSet("calendarid"),
                RelatedEntitiesQuery = new RelationshipQueryCollection
                {
                    {
                        new Relationship("calendar_calendar_rules"),
                        new QueryExpression("calendarrule")
                        {
                            ColumnSet = new ColumnSet("starttime", "duration", "offset", "pattern", "effectiveintervalstart", "effectiveintervalend", "innercalendarid", "timezonecode")
                        }
                    }
                }
            };

            var calendar = ((RetrieveResponse)_service.Execute(request)).Entity;

            if (calendar.RelatedEntities == null ||
                !calendar.RelatedEntities.TryGetValue(new Relationship("calendar_calendar_rules"), out var ruleCollection))
            {
                _tracing.Trace("[pwrp] calendar {0} returned no rule collection", calendarId);
                return new List<Entity>();
            }

            return ruleCollection.Entities.ToList();
        }

        /// <summary>
        /// Flattens the calendar into one rule per opening window per weekday pattern.
        /// </summary>
        /// <remarks>
        /// The calendar is two levels deep, confirmed against a real environment 2026-09-04.
        ///
        /// The outer rule carries the recurrence and nothing about time of day. It has
        /// duration 1440, a pattern such as FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR, the
        /// effective interval, and innercalendarid.
        ///
        /// The inner calendar holds the actual window, as offset and duration in minutes
        /// from midnight. 08:00 to 17:00 is offset 480, duration 540. Inner rules carry no
        /// starttime and no pattern at all.
        ///
        /// Reading starttime and duration off the outer rule, as this did originally, yields
        /// a window of midnight to midnight for every day the calendar is open.
        /// </remarks>
        private List<Rule> LoadRules(Guid calendarId)
        {
            var rules = new List<Rule>();

            foreach (var outer in LoadCalendarRules(calendarId))
            {
                var days = new HashSet<DayOfWeek>(ParseByDay(outer.GetAttributeValue<string>("pattern") ?? string.Empty));
                var effectiveFrom = outer.GetAttributeValue<DateTime?>("effectiveintervalstart");
                var effectiveTo = outer.GetAttributeValue<DateTime?>("effectiveintervalend");
                var inner = outer.GetAttributeValue<EntityReference>("innercalendarid");

                if (inner != null)
                {
                    foreach (var window in LoadCalendarRules(inner.Id))
                    {
                        var minutes = window.GetAttributeValue<int>("duration");
                        rules.Add(new Rule
                        {
                            Start = TimeSpan.FromMinutes(window.GetAttributeValue<int>("offset")),
                            DurationMinutes = minutes,
                            IsClosure = minutes == 0,
                            EffectiveFrom = effectiveFrom,
                            EffectiveTo = effectiveTo,
                            Days = days
                        });
                    }

                    continue;
                }

                // A rule with no inner calendar describes itself. Holiday closures arrive
                // this way, with a duration of zero over an effective interval.
                var outerMinutes = outer.GetAttributeValue<int>("duration");
                rules.Add(new Rule
                {
                    Start = outer.GetAttributeValue<DateTime>("starttime").TimeOfDay,
                    DurationMinutes = outerMinutes,
                    IsClosure = outerMinutes == 0,
                    EffectiveFrom = effectiveFrom,
                    EffectiveTo = effectiveTo,
                    Days = days
                });
            }

            _tracing.Trace("[pwrp] loaded {0} opening windows for calendar {1}", rules.Count, calendarId);
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
