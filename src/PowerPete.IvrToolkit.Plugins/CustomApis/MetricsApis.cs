using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Metrics;
using PowerPete.IvrToolkit.Queues;
using PowerPete.IvrToolkit.Speech;
using Newtonsoft.Json;

namespace PowerPete.IvrToolkit.CustomApis
{
    /// <summary>
    /// pwrp_GetQueueMetrics. Longest wait, average wait, waiting now, availability, estimate.
    ///
    /// Raw seconds are here for supervisors and for your own tuning. Give the caller
    /// WaitBand and Speakable, not the numbers.
    /// </summary>
    public class GetQueueMetrics : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var queue = new QueueResolver(request.Service, request.Config, request.Tracing).Resolve(request.RequireString("Queue"));
            var metrics = new QueueMetricsReader(request.Service, request.Config, request.Tracing).Read(queue);

            request.SetOutput("Metrics", JsonConvert.SerializeObject(metrics));
            request.SetOutput("WaitingNow", metrics.WaitingNow);
            request.SetOutput("LongestWaitSeconds", metrics.LongestWaitSeconds);
            request.SetOutput("AverageWaitSeconds", metrics.AverageWaitSeconds);
            request.SetOutput("EstimatedWaitSeconds", metrics.EstimatedWaitSeconds ?? 0);
            request.SetOutput("RepresentativesAvailable", metrics.RepresentativesAvailable);
            request.SetOutput("RepresentativesOnline", metrics.RepresentativesOnline);
            request.SetOutput("WaitBand", metrics.WaitBand);
            request.SetOutput("Speakable", SpeakableFormatter.DescribeWait(metrics.WaitBand, queue.Locale));
        }
    }
}
