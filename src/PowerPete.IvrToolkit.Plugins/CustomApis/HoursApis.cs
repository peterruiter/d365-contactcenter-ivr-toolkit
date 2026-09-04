using System;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Hours;
using PowerPete.IvrToolkit.Queues;
using Newtonsoft.Json;

namespace PowerPete.IvrToolkit.CustomApis
{
    /// <summary>pwrp_GetQueueHours. Hours for a date range. Use Days=1 for "today", 7 for "this week".</summary>
    public class GetQueueHours : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var queue = new QueueResolver(request.Service, request.Config, request.Tracing).Resolve(request.RequireString("Queue"));
            var from = request.GetDate("FromDate") ?? DateTime.UtcNow;
            var days = Math.Min(Math.Max(request.GetInt("Days", 1), 1), 31);

            var hours = new HoursService(request.Service, request.Config, request.Tracing).GetHours(queue, from, days);

            request.SetOutput("Hours", JsonConvert.SerializeObject(hours));
            request.SetOutput("Speakable", string.Join(". ", hours.Select(h => h.Speakable)));
        }
    }

    /// <summary>pwrp_IsQueueOpen. Now, or at a future moment. Use the future form to validate a callback slot.</summary>
    public class IsQueueOpen : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var queue = new QueueResolver(request.Service, request.Config, request.Tracing).Resolve(request.RequireString("Queue"));
            var at = request.GetDate("AtUtc") ?? DateTime.UtcNow;

            var state = new HoursService(request.Service, request.Config, request.Tracing).GetOpenState(queue, at);

            request.SetOutput("IsOpen", state.IsOpen);
            request.SetOutput("Reason", state.Reason);
            request.SetOutput("NextOpenUtc", state.NextOpenUtc);
            request.SetOutput("NextCloseUtc", state.NextCloseUtc);
            request.SetOutput("Speakable", state.Speakable);
        }
    }

    /// <summary>
    /// pwrp_GetNextOpenTime. The hours answer an IVR actually needs.
    /// Returns the datetime plus a phrase the agent can read straight out.
    /// </summary>
    public class GetNextOpenTime : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var queue = new QueueResolver(request.Service, request.Config, request.Tracing).Resolve(request.RequireString("Queue"));
            var state = new HoursService(request.Service, request.Config, request.Tracing).GetOpenState(queue, DateTime.UtcNow);

            request.SetOutput("IsOpenNow", state.IsOpen);
            request.SetOutput("NextOpenUtc", state.NextOpenUtc);
            request.SetOutput("Speakable", state.Speakable);
        }
    }
}
