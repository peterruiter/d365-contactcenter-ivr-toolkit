using System;
using PowerPete.IvrToolkit.Callback;
using PowerPete.IvrToolkit.Common;
using Newtonsoft.Json;

namespace PowerPete.IvrToolkit.CustomApis
{
    /// <summary>
    /// pwrp_PromoteDueCallbacks. Called by the Power Pete Promote Due Callbacks flow.
    /// Not for agents. Idempotent, so a double run is harmless.
    /// </summary>
    public class PromoteDueCallbacks : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var scheduler = new CallbackScheduler(request.Service, request.Config, request.Tracing);
            var result = scheduler.PromoteDue(request.GetInt("LookAheadMinutes", 5));

            request.SetOutput("Promoted", result.Promoted);
            request.SetOutput("Retried", result.Retried);
            request.SetOutput("Failed", result.Failed);
            request.SetOutput("Expired", result.Expired);
            request.SetOutput("Reconciled", result.Reconciled);
            request.SetOutput("References", JsonConvert.SerializeObject(result.References));
        }
    }

    /// <summary>
    /// pwrp_RecordCallbackOutcome. Called after a dial finishes so the retry policy can act.
    /// Wire this into your proactive engagement completion path. Skip it and every callback
    /// sits in Dialling forever.
    /// </summary>
    public class RecordCallbackOutcome : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            if (!Guid.TryParse(request.RequireString("CallbackId"), out var id))
            {
                throw new ToolkitException(ErrorCodes.InvalidInput, "CallbackId must be a guid.");
            }

            var scheduler = new CallbackScheduler(request.Service, request.Config, request.Tracing);
            request.SetOutput("Status", scheduler.RecordOutcome(id, request.RequireString("Outcome"), request.GetString("Detail")));
        }
    }
}
