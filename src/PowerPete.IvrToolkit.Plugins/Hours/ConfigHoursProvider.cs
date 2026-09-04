using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Model;
using PowerPete.IvrToolkit.Speech;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace PowerPete.IvrToolkit.Hours
{
    /// <summary>
    /// Reads pwrp_queuehours (one row per weekday window) and pwrp_holiday (date overrides).
    /// A holiday row with no windows closes the day. A holiday row with windows overrides them.
    /// </summary>
    public class ConfigHoursProvider : IHoursProvider
    {
        private readonly IOrganizationService _service;

        public ConfigHoursProvider(IOrganizationService service)
        {
            _service = service;
        }

        public List<DayHours> GetHours(QueueRef queue, DateTime fromLocal, int days)
        {
            var weekly = LoadWeekly(queue.QueueId);
            var holidays = LoadHolidays(queue.QueueId, fromLocal.Date, fromLocal.Date.AddDays(days));
            var result = new List<DayHours>();

            for (var offset = 0; offset < days; offset++)
            {
                var date = fromLocal.Date.AddDays(offset);
                var day = new DayHours { Date = date, DayOfWeek = date.DayOfWeek.ToString() };

                if (holidays.TryGetValue(date, out var holiday))
                {
                    day.Windows = holiday.Windows.Select(w => new OpeningWindow
                    {
                        StartLocal = date.Add(w.Item1),
                        EndLocal = date.Add(w.Item2),
                        IsHoliday = true,
                        HolidayName = holiday.Name
                    }).ToList();
                }
                else
                {
                    day.Windows = weekly
                        .Where(w => w.Day == date.DayOfWeek)
                        .Select(w => new OpeningWindow { StartLocal = date.Add(w.Start), EndLocal = date.Add(w.End) })
                        .OrderBy(w => w.StartLocal)
                        .ToList();
                }

                day.IsOpen = day.Windows.Count > 0;
                day.Speakable = SpeakableFormatter.DescribeDay(day, queue.Locale);
                result.Add(day);
            }

            return result;
        }

        private class WeeklyRow
        {
            public DayOfWeek Day;
            public TimeSpan Start;
            public TimeSpan End;
        }

        private List<WeeklyRow> LoadWeekly(Guid queueId)
        {
            var query = new QueryExpression("pwrp_queuehours")
            {
                ColumnSet = new ColumnSet("pwrp_dayofweek", "pwrp_starttime", "pwrp_endtime"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("pwrp_queueid", ConditionOperator.Equal, queueId),
                        new ConditionExpression("statecode", ConditionOperator.Equal, 0)
                    }
                }
            };

            return _service.RetrieveMultiple(query).Entities.Select(e => new WeeklyRow
            {
                Day = (DayOfWeek)(e.GetAttributeValue<OptionSetValue>("pwrp_dayofweek")?.Value ?? 0),
                Start = TimeSpan.Parse(e.GetAttributeValue<string>("pwrp_starttime") ?? "09:00"),
                End = TimeSpan.Parse(e.GetAttributeValue<string>("pwrp_endtime") ?? "17:00")
            }).ToList();
        }

        private class HolidayRow
        {
            public string Name;
            public List<Tuple<TimeSpan, TimeSpan>> Windows = new List<Tuple<TimeSpan, TimeSpan>>();
        }

        private Dictionary<DateTime, HolidayRow> LoadHolidays(Guid queueId, DateTime from, DateTime to)
        {
            var query = new QueryExpression("pwrp_holiday")
            {
                ColumnSet = new ColumnSet("pwrp_name", "pwrp_date", "pwrp_starttime", "pwrp_endtime", "pwrp_queueid"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("pwrp_date", ConditionOperator.OnOrAfter, from),
                        new ConditionExpression("pwrp_date", ConditionOperator.OnOrBefore, to),
                        new ConditionExpression("statecode", ConditionOperator.Equal, 0)
                    }
                }
            };

            // A holiday with no queue applies to every queue. A queue-specific row wins.
            var rows = _service.RetrieveMultiple(query).Entities
                .Where(e =>
                {
                    var reference = e.GetAttributeValue<EntityReference>("pwrp_queueid");
                    return reference == null || reference.Id == queueId;
                })
                .OrderBy(e => e.GetAttributeValue<EntityReference>("pwrp_queueid") == null ? 0 : 1);

            var map = new Dictionary<DateTime, HolidayRow>();
            foreach (var row in rows)
            {
                var date = row.GetAttributeValue<DateTime>("pwrp_date").Date;
                var holiday = new HolidayRow { Name = row.GetAttributeValue<string>("pwrp_name") };

                var start = row.GetAttributeValue<string>("pwrp_starttime");
                var end = row.GetAttributeValue<string>("pwrp_endtime");
                if (!string.IsNullOrWhiteSpace(start) && !string.IsNullOrWhiteSpace(end))
                {
                    holiday.Windows.Add(Tuple.Create(TimeSpan.Parse(start), TimeSpan.Parse(end)));
                }

                map[date] = holiday;
            }

            return map;
        }
    }
}
