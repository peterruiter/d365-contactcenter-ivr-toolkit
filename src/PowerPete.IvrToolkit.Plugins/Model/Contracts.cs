using System;
using System.Collections.Generic;

namespace PowerPete.IvrToolkit.Model
{
    /// <summary>Resolved queue identity. Every endpoint accepts a name or a GUID and returns this.</summary>
    public class QueueRef
    {
        public Guid QueueId { get; set; }
        public string Name { get; set; }
        public string SpeakableName { get; set; }
        public string ChannelType { get; set; }
        public string TimeZone { get; set; }
        public string Locale { get; set; }

        /// <summary>
        /// Country calling code for phone normalisation, digits only.
        /// </summary>
        /// <remarks>
        /// Per queue because a national format number means a different thing in each
        /// market. "0475 123456" read against the wrong country becomes a valid looking
        /// number in the right one, with no error and a callback booked to a stranger.
        /// </remarks>
        public string CountryCode { get; set; }

        public Guid? ProfileId { get; set; }
    }

    public class OpeningWindow
    {
        public DateTime StartLocal { get; set; }
        public DateTime EndLocal { get; set; }
        public bool IsHoliday { get; set; }
        public string HolidayName { get; set; }
    }

    public class DayHours
    {
        public DateTime Date { get; set; }
        public string DayOfWeek { get; set; }
        public bool IsOpen { get; set; }

        /// <summary>
        /// On the day, not only on its windows. A full closure has no windows, so a flag
        /// that lived only there was invisible on exactly the days that matter most.
        /// </summary>
        public bool IsHoliday { get; set; }

        public string HolidayName { get; set; }
        public List<OpeningWindow> Windows { get; set; } = new List<OpeningWindow>();
        public string Speakable { get; set; }
    }

    public class OpenState
    {
        public bool IsOpen { get; set; }
        /// <summary>Open, Closed, Holiday, OutsideHours, NotConfigured.</summary>
        public string Reason { get; set; }

        /// <summary>The holiday's name when Reason is Holiday and the source knows one.</summary>
        public string HolidayName { get; set; }
        public DateTime? NextOpenUtc { get; set; }
        public DateTime? NextCloseUtc { get; set; }
        public string Speakable { get; set; }
    }

    public class QueueMetrics
    {
        public int WaitingNow { get; set; }
        public int LongestWaitSeconds { get; set; }
        public int AverageWaitSeconds { get; set; }
        public int RepresentativesAvailable { get; set; }
        public int RepresentativesOnline { get; set; }
        public int AvailableCapacityUnits { get; set; }
        public int? EstimatedWaitSeconds { get; set; }
        /// <summary>Short, Moderate, Long, VeryLong. Give this to the caller, not the raw seconds.</summary>
        public string WaitBand { get; set; }
        public DateTime AsOfUtc { get; set; }
        public bool IsStale { get; set; }
    }

    /// <summary>Single composite payload for a real-time voice agent. One call, one decision.</summary>
    public class QueueContext
    {
        public QueueRef Queue { get; set; }
        public OpenState OpenState { get; set; }
        public QueueMetrics Metrics { get; set; }
        public string BroadcastMessage { get; set; }
        public bool DirectCallbackAvailable { get; set; }
        public bool ScheduledCallbackAvailable { get; set; }
        /// <summary>Serve, OfferCallback, OfferVoicemail, AnnounceClosed, AnnounceOutage.</summary>
        public string RecommendedAction { get; set; }
        public string Speakable { get; set; }
    }

    public class CallbackSlot
    {
        public DateTime StartUtc { get; set; }
        public DateTime EndUtc { get; set; }
        public int RemainingCapacity { get; set; }
        public string Speakable { get; set; }
    }

    public class CallbackRecord
    {
        public Guid CallbackId { get; set; }
        public string Reference { get; set; }
        public string PhoneNumber { get; set; }
        public Guid QueueId { get; set; }
        public string Mode { get; set; }
        public DateTime? ScheduledStartUtc { get; set; }
        public string Status { get; set; }
        public int Attempts { get; set; }
        public string Speakable { get; set; }

        /// <summary>
        /// True when Create returned a request that already existed instead of making one.
        /// </summary>
        /// <remarks>
        /// Deduplication is deliberate, but it was invisible from outside, so an agent
        /// could not tell a fresh booking from a repeat and had to read the reference back
        /// as though it were new either way.
        /// </remarks>
        public bool IsExisting { get; set; }
    }
}
