using System;
using System.Linq;
using PowerPete.IvrToolkit.Callback;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Hours;
using PowerPete.IvrToolkit.Queues;
using Newtonsoft.Json;

namespace PowerPete.IvrToolkit.CustomApis
{
    internal static class CallbackFactory
    {
        public static CallbackService Build(ToolkitRequest request)
        {
            var hours = new HoursService(request.Service, request.Config, request.Tracing);
            return new CallbackService(request.Service, request.Config, hours, request.Tracing);
        }

        public static Model.QueueRef Queue(ToolkitRequest request)
        {
            return new QueueResolver(request.Service, request.Config, request.Tracing).Resolve(request.RequireString("Queue"));
        }
    }

    /// <summary>pwrp_CheckCallbackEligibility. Ask before you offer.</summary>
    public class CheckCallbackEligibility : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var queue = CallbackFactory.Queue(request);
            var service = CallbackFactory.Build(request);

            var direct = service.DirectCallbackEnabled(queue);
            var scheduled = service.ScheduledCallbackEnabled(queue);

            request.SetOutput("DirectCallbackAvailable", direct);
            request.SetOutput("ScheduledCallbackAvailable", scheduled);
            request.SetOutput("AnyAvailable", direct || scheduled);
        }
    }

    /// <summary>pwrp_GetCallbackSlots. Bookable windows inside opening hours, capacity aware.</summary>
    public class GetCallbackSlots : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var queue = CallbackFactory.Queue(request);
            var days = Math.Min(Math.Max(request.GetInt("Days", 3), 1), 14);
            var maximum = Math.Min(Math.Max(request.GetInt("MaxResults", 6), 1), 50);

            var slots = CallbackFactory.Build(request).GetSlots(queue, DateTime.UtcNow, days).Take(maximum).ToList();

            request.SetOutput("Slots", JsonConvert.SerializeObject(slots));
            request.SetOutput("Count", slots.Count);
            // Offering three options over the phone is plenty. More and the caller loses track.
            request.SetOutput("Speakable", string.Join(", ", slots.Take(3).Select(s => s.Speakable)));
        }
    }

    /// <summary>pwrp_CreateCallback. Mode is Direct or Scheduled. Idempotent per queue and number.</summary>
    public class CreateCallback : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            var queue = CallbackFactory.Queue(request);
            var contactRaw = request.GetString("ContactId");
            Guid? contactId = Guid.TryParse(contactRaw, out var parsed) ? parsed : (Guid?)null;

            var record = CallbackFactory.Build(request).Create(
                queue,
                request.RequireString("PhoneNumber"),
                request.GetDate("RequestedStartUtc"),
                request.GetString("Mode", "Direct"),
                request.GetString("ContextJson"),
                contactId,
                request.GetString("ConversationId"));

            request.SetOutput("Callback", JsonConvert.SerializeObject(record));
            request.SetOutput("CallbackId", record.CallbackId.ToString());
            request.SetOutput("Reference", record.Reference);
            request.SetOutput("IsExisting", record.IsExisting);
            request.SetOutput("Status", record.Status);
            request.SetOutput("Speakable", record.Speakable);
        }
    }

    /// <summary>pwrp_GetCallbackStatus. Reference, phone number or id. Reference is easiest over the phone.</summary>
    public class GetCallbackStatus : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            Guid.TryParse(request.GetString("CallbackId"), out var id);

            var record = CallbackFactory.Build(request).GetStatus(
                request.GetString("Reference"),
                request.GetString("PhoneNumber"),
                id == Guid.Empty ? (Guid?)null : id);

            request.SetOutput("Callback", JsonConvert.SerializeObject(record));
            request.SetOutput("Status", record.Status);
            request.SetOutput("Attempts", record.Attempts);
        }
    }

    /// <summary>pwrp_CancelCallback.</summary>
    public class CancelCallback : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            if (!Guid.TryParse(request.RequireString("CallbackId"), out var id))
            {
                throw new ToolkitException(ErrorCodes.InvalidInput, "CallbackId must be a guid.");
            }

            var record = CallbackFactory.Build(request).Cancel(id);
            request.SetOutput("Status", record.Status);
            request.SetOutput("Callback", JsonConvert.SerializeObject(record));
        }
    }

    /// <summary>pwrp_RescheduleCallback.</summary>
    public class RescheduleCallback : ToolkitPluginBase
    {
        protected override void Handle(ToolkitRequest request)
        {
            if (!Guid.TryParse(request.RequireString("CallbackId"), out var id))
            {
                throw new ToolkitException(ErrorCodes.InvalidInput, "CallbackId must be a guid.");
            }

            var start = request.GetDate("NewStartUtc");
            if (!start.HasValue)
            {
                throw new ToolkitException(ErrorCodes.InvalidInput, "NewStartUtc is required.");
            }

            var record = CallbackFactory.Build(request).Reschedule(CallbackFactory.Queue(request), id, start.Value);
            request.SetOutput("Status", record.Status);
            request.SetOutput("Callback", JsonConvert.SerializeObject(record));
            request.SetOutput("Speakable", record.Speakable);
        }
    }
}
