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
            request.SetOutput("BroadcastMessage", context.BroadcastMessage ?? string.Empty);
            request.SetOutput("IsOpen", context.OpenState.IsOpen);
            request.SetOutput("WaitBand", context.Metrics.WaitBand);
            // Promoted out of the Context payload. An agent binds to outputs, and having
            // to parse a JSON string mid call was costing a second round trip to
            // CheckCallbackEligibility on the most latency sensitive path there is.
            request.SetOutput("DirectCallbackAvailable", context.DirectCallbackAvailable);
            request.SetOutput("ScheduledCallbackAvailable", context.ScheduledCallbackAvailable);
            request.SetOutput("RecommendedAction", context.RecommendedAction);
            request.SetOutput("Speakable", context.Speakable);
        }

        /// <summary>
        /// One decision, returned as an enum so the agent branches deterministically instead
        /// of reasoning its way to an inconsistent answer on every call.
        /// </summary>
        private static string Recommend(QueueContext context)
        {
            if (!context.OpenState.IsOpen) return "AnnounceClosed";

            // Anything but Short means the caller waits longer than the first threshold in
            // pwrp_WaitBandThresholds, which is where the tuning lives. Offering a callback
            // is about the wait, so the wait decides it.
            if (context.Metrics.WaitBand != "Short")
            {
                if (context.ScheduledCallbackAvailable || context.DirectCallbackAvailable) return "OfferCallback";
                return "OfferVoicemail";
            }

            return "Serve";
        }

        /// <summary>
        /// What to say about the queue itself.
        /// </summary>
        /// <remarks>
        /// A broadcast message used to be returned here and as AnnounceOutage, which meant
        /// an announcement replaced the wait entirely: a caller heard "we are busy" and was
        /// never told how long or offered a callback. An announcement is something to read,
        /// not something to do, so it comes back as its own output and this describes the
        /// queue as it always did.
        /// </remarks>
        private static string BuildSpeakable(QueueContext context)
        {
            var locale = context.Queue.Locale;

            if (!context.OpenState.IsOpen)
            {
                return context.OpenState.Speakable;
            }

            return SpeakableFormatter.DescribeWait(context.Metrics.WaitBand, locale);
        }
    }
}
