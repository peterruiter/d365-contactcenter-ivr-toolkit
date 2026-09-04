using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Model;
using PowerPete.IvrToolkit.Speech;
using Microsoft.Crm.Sdk.Messages;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace PowerPete.IvrToolkit.Hours
{
    /// <summary>
    /// Reads the native operating hours calendar.
    ///
    /// The calendar rules are expanded by the platform through ExpandCalendarRequest rather
    /// than parsed here. That message is supported, and it returns concrete UTC blocks with
    /// the recurrence, the timezone and daylight saving already applied.
    ///
    /// This used to walk the rules by hand, and got it wrong twice. The outer rule carries
    /// only the recurrence, so reading its duration reported every day as open around the
    /// clock. The real window lives on an inner calendar as an offset in minutes from
    /// midnight, and whether that offset is local or UTC could not be settled from the data:
    /// the one calendar available to check disagreed with its own name under either reading.
    /// Asking the platform removes the question rather than answering it.
    ///
    /// SUPPORT NOTE: only the walk from queue to calendar below is internal schema now.
    /// If a wave update breaks that, switch the affected queue profiles to config hours.
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

            var timeZone = HoursService.ResolveTimeZone(queue.TimeZone);
            var firstDay = fromLocal.Date;

            // A day of slack either side. A block can start before local midnight or run past
            // it, and asking for exactly the local range would drop the overlapping part.
            var fromUtc = TimeZoneInfo.ConvertTimeToUtc(firstDay, timeZone).AddDays(-1);
            var toUtc = TimeZoneInfo.ConvertTimeToUtc(firstDay.AddDays(days), timeZone).AddDays(1);

            var response = (ExpandCalendarResponse)_service.Execute(new ExpandCalendarRequest
            {
                CalendarId = calendarId.Value,
                Start = fromUtc,
                End = toUtc
            });

            // Available is the working time. Holiday, vacation and break blocks come back
            // under another code and simply leave the day without hours, which is the answer
            // a caller needs anyway.
            var openBlocks = (response.result ?? new TimeInfo[0])
                .Where(block => block.TimeCode == TimeCode.Available && block.Start.HasValue && block.End.HasValue)
                .Select(block => new
                {
                    StartLocal = ToLocal(block.Start.Value, timeZone),
                    EndLocal = ToLocal(block.End.Value, timeZone)
                })
                .Where(block => block.EndLocal > block.StartLocal)
                .ToList();

            _tracing.Trace("[pwrp] calendar {0} expanded to {1} available blocks", calendarId, openBlocks.Count);

            var result = new List<DayHours>();

            for (var offset = 0; offset < days; offset++)
            {
                var date = firstDay.AddDays(offset);
                var nextDate = date.AddDays(1);
                var day = new DayHours { Date = date, DayOfWeek = date.DayOfWeek.ToString() };

                // Clip to the day, so a block spanning midnight belongs to both days it covers.
                day.Windows = openBlocks
                    .Where(block => block.StartLocal < nextDate && block.EndLocal > date)
                    .Select(block => new OpeningWindow
                    {
                        StartLocal = block.StartLocal < date ? date : block.StartLocal,
                        EndLocal = block.EndLocal > nextDate ? nextDate : block.EndLocal
                    })
                    .OrderBy(window => window.StartLocal)
                    .ToList();

                day.IsOpen = day.Windows.Count > 0;
                day.Speakable = SpeakableFormatter.DescribeDay(day, queue.Locale);
                result.Add(day);
            }

            return result;
        }

        private static DateTime ToLocal(DateTime utc, TimeZoneInfo timeZone)
        {
            // ExpandCalendar answers in UTC, but does not always say so on the value itself.
            return TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), timeZone);
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
    }
}
