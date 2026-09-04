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
        public List<OpeningWindow> Windows { get; set; } = new List<OpeningWindow>();
        public string Speakable { get; set; }
    }

    public class OpenState
    {
        public bool IsOpen { get; set; }
        /// <summary>Open, Closed, Holiday, OutsideHours, NotConfigured.</summary>
        public string Reason { get; set; }
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
    }
}
