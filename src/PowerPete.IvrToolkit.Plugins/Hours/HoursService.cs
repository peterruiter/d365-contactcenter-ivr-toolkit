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
    /// <summary>Picks the provider, converts time zones, answers the open/closed questions.</summary>
    public class HoursService
    {
        private readonly IOrganizationService _service;
        private readonly ConfigReader _config;
        private readonly ITracingService _tracing;

        public HoursService(IOrganizationService service, ConfigReader config, ITracingService tracing)
        {
            _service = service;
            _config = config;
            _tracing = tracing;
        }

        public List<DayHours> GetHours(QueueRef queue, DateTime fromUtc, int days)
        {
            var ttl = _config.GetInt(ConfigKeys.HoursCacheSeconds, 300);
            var key = $"hours:{queue.QueueId}:{fromUtc:yyyyMMdd}:{days}";

            return CacheStore.GetOrAdd(key, ttl, () =>
            {
                var tz = ResolveTimeZone(queue.TimeZone);
                var fromLocal = TimeZoneInfo.ConvertTimeFromUtc(fromUtc, tz);
                return SelectProvider(queue).GetHours(queue, fromLocal, days);
            });
        }

        public OpenState GetOpenState(QueueRef queue, DateTime atUtc)
        {
            var tz = ResolveTimeZone(queue.TimeZone);
            var atLocal = TimeZoneInfo.ConvertTimeFromUtc(atUtc, tz);

            // Look 14 days ahead so "next open" survives a long holiday closure.
            var days = GetHours(queue, atUtc.Date, 15);
            var today = days.FirstOrDefault(d => d.Date == atLocal.Date);

            var state = new OpenState();
            var window = today?.Windows.FirstOrDefault(w => atLocal >= w.StartLocal && atLocal < w.EndLocal);

            if (window != null)
            {
                state.IsOpen = true;
                state.Reason = "Open";
                state.NextCloseUtc = TimeZoneInfo.ConvertTimeToUtc(window.EndLocal, tz);
            }
            else
            {
                state.IsOpen = false;
                state.HolidayName = today == null ? null : today.HolidayName;
                // today.IsHoliday, not today.Windows.Any(...). A day closed outright has no
                // windows, so the old test could only ever be true for a holiday that was a
                // short day. Christmas Day reported OutsideHours.
                state.Reason = today != null && today.IsHoliday ? "Holiday"
                    : today == null || today.Windows.Count == 0 ? "Closed"
                    : "OutsideHours";

                var next = days
                    .SelectMany(d => d.Windows)
                    .Where(w => w.StartLocal > atLocal)
                    .OrderBy(w => w.StartLocal)
                    .FirstOrDefault();

                if (next != null)
                {
                    state.NextOpenUtc = TimeZoneInfo.ConvertTimeToUtc(next.StartLocal, tz);
                }
            }

            state.Speakable = SpeakableFormatter.DescribeOpenState(state, queue, tz);
            return state;
        }

        private IHoursProvider SelectProvider(QueueRef queue)
        {
            var mode = "operatinghours";

            if (queue.ProfileId.HasValue)
            {
                var profile = _service.Retrieve("pwrp_queueprofile", queue.ProfileId.Value, new ColumnSet("pwrp_hourssource"));
                var option = profile.GetAttributeValue<OptionSetValue>("pwrp_hourssource");
                // 1 = native operating hours, 2 = toolkit config tables
                mode = option?.Value == 2 ? "config" : "operatinghours";
            }

            _tracing.Trace("[pwrp] hours provider for {0}: {1}", queue.Name, mode);

            return mode == "config"
                ? (IHoursProvider)new ConfigHoursProvider(_service)
                : new OperatingHoursProvider(_service, _tracing);
        }

        public static TimeZoneInfo ResolveTimeZone(string id)
        {
            try
            {
                return TimeZoneInfo.FindSystemTimeZoneById(id);
            }
            catch (Exception)
            {
                return TimeZoneInfo.FindSystemTimeZoneById("W. Europe Standard Time");
            }
        }
    }
}
