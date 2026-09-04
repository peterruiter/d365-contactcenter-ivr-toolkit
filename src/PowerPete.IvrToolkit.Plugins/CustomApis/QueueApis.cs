using System;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Hours;
using PowerPete.IvrToolkit.Metrics;
using PowerPete.IvrToolkit.Model;
using PowerPete.IvrToolkit.Queues;
using PowerPete.IvrToolkit.Speech;
using Newtonsoft.Json;

namespace PowerPete.IvrToolkit.CustomApis
{
    /// <summary>pwrp_GetQueues. Lists queues the agent may route to. Cached, so cheap to call.</summary>
    public class GetQueues : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var resolver = new QueueResolver(request.Service, request.Config, request.Tracing);
            var queues = resolver.ListQueues(request.GetString("ChannelType"));

            request.SetOutput("Queues", JsonConvert.SerializeObject(queues));
            request.SetOutput("Count", queues.Count);
            request.SetOutput("Speakable", string.Join(", ", queues.Select(q => q.SpeakableName)));
        }
    }

    /// <summary>
    /// pwrp_ResolveQueue. Turns a spoken queue name into an id.
    /// Call this once at the start of a conversation and hold the id in a variable.
    /// </summary>
    public class ResolveQueue : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var resolver = new QueueResolver(request.Service, request.Config, request.Tracing);
            var queue = resolver.Resolve(request.RequireString("Queue"));

            request.SetOutput("QueueId", queue.QueueId.ToString());
            request.SetOutput("QueueName", queue.Name);
            request.SetOutput("SpeakableName", queue.SpeakableName);
            request.SetOutput("ChannelType", queue.ChannelType);
            request.SetOutput("Locale", queue.Locale);
        }
    }

    /// <summary>
    /// pwrp_GetQueueContext. The one that matters.
    ///
    /// A real-time voice agent should call this and nothing else at the start of a call.
    /// It returns opening state, live wait band, outage message, callback options and a
    /// recommended action in a single round trip. Nine chatty tool calls turn into silence
    /// the caller hears.
    /// </summary>
    public class GetQueueContext : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var resolver = new QueueResolver(request.Service, request.Config, request.Tracing);
            var queue = resolver.Resolve(request.RequireString("Queue"));

            var hours = new HoursService(request.Service, request.Config, request.Tracing);
            var callbacks = new Callback.CallbackService(request.Service, request.Config, hours, request.Tracing);

            var context = new QueueContext
            {
                Queue = queue,
                OpenState = hours.GetOpenState(queue, DateTime.UtcNow),
                BroadcastMessage = BroadcastReader.Read(request.Service, queue.QueueId),
                DirectCallbackAvailable = callbacks.DirectCallbackEnabled(queue),
                ScheduledCallbackAvailable = callbacks.ScheduledCallbackEnabled(queue)
            };

            // Metrics are the only part allowed to fail without failing the call.
            try
            {
                context.Metrics = new QueueMetricsReader(request.Service, request.Config, request.Tracing).Read(queue);
            }
            catch (ToolkitException ex)
            {
                request.Tracing.Trace("[pwrp] context continuing without metrics: {0}", ex.Code);
                context.Metrics = new QueueMetrics { IsStale = true, WaitBand = "Moderate", AsOfUtc = DateTime.UtcNow };
            }

            context.RecommendedAction = Recommend(context);
            context.Speakable = BuildSpeakable(context);

            request.SetOutput("Context", JsonConvert.SerializeObject(context));
            request.SetOutput("QueueId", queue.QueueId.ToString());
            request.SetOutput("IsOpen", context.OpenState.IsOpen);
            request.SetOutput("WaitBand", context.Metrics.WaitBand);
            request.SetOutput("RecommendedAction", context.RecommendedAction);
            request.SetOutput("Speakable", context.Speakable);
        }

        /// <summary>
        /// One decision, returned as an enum so the agent branches deterministically instead
        /// of reasoning its way to an inconsistent answer on every call.
        /// </summary>
        private static string Recommend(QueueContext context)
        {
            if (!string.IsNullOrWhiteSpace(context.BroadcastMessage)) return "AnnounceOutage";
            if (!context.OpenState.IsOpen) return "AnnounceClosed";

            var band = context.Metrics.WaitBand;
            if (band == "VeryLong" || band == "Long")
            {
                if (context.ScheduledCallbackAvailable || context.DirectCallbackAvailable) return "OfferCallback";
                return "OfferVoicemail";
            }

            return "Serve";
        }

        private static string BuildSpeakable(QueueContext context)
        {
            var locale = context.Queue.Locale;

            if (!string.IsNullOrWhiteSpace(context.BroadcastMessage))
            {
                return context.BroadcastMessage;
            }

            if (!context.OpenState.IsOpen)
            {
                return context.OpenState.Speakable;
            }

            return SpeakableFormatter.DescribeWait(context.Metrics.WaitBand, locale);
        }
    }
}
