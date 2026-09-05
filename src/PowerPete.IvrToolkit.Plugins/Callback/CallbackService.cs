using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Hours;
using PowerPete.IvrToolkit.Model;
using PowerPete.IvrToolkit.Speech;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace PowerPete.IvrToolkit.Callback
{
    /// <summary>
    /// Two callback modes, and only one of them is a build.
    ///
    /// Direct callback is native. Configure it as a queue overflow action in the admin
    /// centre. The platform holds the work item, and when it reaches position one it dials
    /// the customer using preview dialing so a representative accepts first. The toolkit
    /// does not recreate that. It only reports eligibility and status so the agent can
    /// offer it in the right words.
    ///
    /// Scheduled callback is the build, but it still does not include a dialer. A
    /// pwrp_callbackrequest record is written here, a scheduled flow promotes due records
    /// into the outbound workstream, and proactive engagement in preview dial mode places
    /// the call. Owning the dialer would be the wrong call.
    /// </summary>
    public class CallbackService
    {
        private readonly IOrganizationService _service;
        private readonly ConfigReader _config;
        private readonly HoursService _hours;
        private readonly ITracingService _tracing;

        public CallbackService(IOrganizationService service, ConfigReader config, HoursService hours, ITracingService tracing)
        {
            _service = service;
            _config = config;
            _hours = hours;
            _tracing = tracing;
        }

        public bool DirectCallbackEnabled(QueueRef queue)
        {
            return ProfileFlag(queue, "pwrp_directcallbackenabled");
        }

        public bool ScheduledCallbackEnabled(QueueRef queue)
        {
            return _config.GetBool(ConfigKeys.EnableScheduledCallback, false) && ProfileFlag(queue, "pwrp_scheduledcallbackenabled");
        }

        private bool ProfileFlag(QueueRef queue, string attribute)
        {
            if (!queue.ProfileId.HasValue) return false;
            var profile = _service.Retrieve("pwrp_queueprofile", queue.ProfileId.Value, new ColumnSet(attribute));
            return profile.GetAttributeValue<bool>(attribute);
        }

        /// <summary>
        /// Slots are windows inside opening hours with a capacity cap, so the IVR cannot
        /// book fifty callbacks into one ten minute window.
        /// </summary>
        public List<CallbackSlot> GetSlots(QueueRef queue, DateTime fromUtc, int days)
        {
            if (!ScheduledCallbackEnabled(queue))
            {
                throw new ToolkitException(ErrorCodes.CallbackDisabled, "Scheduled callback is off for this queue.");
            }

            var slotMinutes = _config.GetInt(ConfigKeys.CallbackSlotMinutes, 30);
            var capacity = SlotCapacity(queue);
            var tz = HoursService.ResolveTimeZone(queue.TimeZone);
            var hours = _hours.GetHours(queue, fromUtc, days);
            var booked = BookedPerSlot(queue.QueueId, fromUtc, fromUtc.AddDays(days));

            var slots = new List<CallbackSlot>();

            foreach (var day in hours.Where(d => d.IsOpen))
            {
                foreach (var window in day.Windows)
                {
                    var cursor = window.StartLocal;
                    while (cursor.AddMinutes(slotMinutes) <= window.EndLocal)
                    {
                        var startUtc = TimeZoneInfo.ConvertTimeToUtc(cursor, tz);
                        if (startUtc > fromUtc)
                        {
                            var used = booked.ContainsKey(startUtc) ? booked[startUtc] : 0;
                            var remaining = capacity - used;

                            if (remaining > 0)
                            {
                                slots.Add(new CallbackSlot
                                {
                                    StartUtc = startUtc,
                                    EndUtc = startUtc.AddMinutes(slotMinutes),
                                    RemainingCapacity = remaining,
                                    Speakable = SpeakableFormatter.DescribeCallback(cursor, string.Empty, queue.Locale)
                                });
                            }
                        }
                        cursor = cursor.AddMinutes(slotMinutes);
                    }
                }
            }

            return slots;
        }

        public CallbackRecord Create(QueueRef queue, string rawNumber, DateTime? requestedStartUtc, string mode, string contextJson, Guid? contactId, string conversationId)
        {
            // The queue decides the country. A national format number means a different
            // number in each market, and reading it against the wrong one produces a valid
            // looking number in the right one rather than an error.
            var phone = PhoneNumberValidator.Validate(rawNumber, queue.CountryCode);
            if (!phone.IsValid)
            {
                throw new ToolkitException(ErrorCodes.InvalidPhoneNumber, phone.Reason);
            }

            var scheduled = string.Equals(mode, "Scheduled", StringComparison.OrdinalIgnoreCase);

            if (scheduled && !ScheduledCallbackEnabled(queue))
            {
                throw new ToolkitException(ErrorCodes.CallbackDisabled, "Scheduled callback is off for this queue.");
            }

            if (!scheduled && !DirectCallbackEnabled(queue))
            {
                throw new ToolkitException(ErrorCodes.CallbackDisabled, "Callback is off for this queue.");
            }

            // Deduplicate. A voice agent will retry on a timeout, and a caller who
            // repeats themselves should not end up with three callbacks.
            var existing = FindOpen(queue.QueueId, phone.E164);
            if (existing != null)
            {
                _tracing.Trace("[pwrp] duplicate callback suppressed for {0}", phone.E164);
                existing.IsExisting = true;
                return existing;
            }

            if (scheduled)
            {
                if (!requestedStartUtc.HasValue)
                {
                    throw new ToolkitException(ErrorCodes.InvalidInput, "A scheduled callback needs a requested start time.");
                }

                var slots = GetSlots(queue, DateTime.UtcNow, 14);
                if (slots.All(s => s.StartUtc != requestedStartUtc.Value))
                {
                    throw new ToolkitException(ErrorCodes.CallbackSlotUnavailable, "That time is not available.");
                }
            }

            var record = new Entity("pwrp_callbackrequest")
            {
                ["pwrp_name"] = NewReference(),
                ["pwrp_phonenumber"] = phone.E164,
                ["pwrp_numbertype"] = phone.NumberType,
                ["pwrp_queueid"] = new EntityReference("queue", queue.QueueId),
                ["pwrp_mode"] = new OptionSetValue(scheduled ? 2 : 1),
                ["pwrp_status"] = new OptionSetValue(1), // Requested
                ["pwrp_attempts"] = 0,
                ["pwrp_requestedstart"] = requestedStartUtc,
                ["pwrp_locale"] = queue.Locale,
                ["pwrp_context"] = contextJson,
                ["pwrp_conversationid"] = conversationId
            };

            if (contactId.HasValue)
            {
                record["pwrp_contactid"] = new EntityReference("contact", contactId.Value);
            }

            var id = _service.Create(record);
            var tz = HoursService.ResolveTimeZone(queue.TimeZone);

            return new CallbackRecord
            {
                CallbackId = id,
                Reference = (string)record["pwrp_name"],
                PhoneNumber = phone.E164,
                QueueId = queue.QueueId,
                Mode = scheduled ? "Scheduled" : "Direct",
                ScheduledStartUtc = requestedStartUtc,
                Status = "Requested",
                Attempts = 0,
                Speakable = SpeakableFormatter.DescribeCallback(
                    requestedStartUtc.HasValue ? TimeZoneInfo.ConvertTimeFromUtc(requestedStartUtc.Value, tz) : (DateTime?)null,
                    phone.E164,
                    queue.Locale)
            };
        }

        public CallbackRecord GetStatus(string reference, string phoneNumber, Guid? callbackId)
        {
            var query = new QueryExpression("pwrp_callbackrequest")
            {
                ColumnSet = new ColumnSet("pwrp_name", "pwrp_phonenumber", "pwrp_queueid", "pwrp_mode", "pwrp_status", "pwrp_attempts", "pwrp_requestedstart"),
                TopCount = 1,
                Orders = { new OrderExpression("createdon", OrderType.Descending) }
            };

            if (callbackId.HasValue)
            {
                query.Criteria.AddCondition("pwrp_callbackrequestid", ConditionOperator.Equal, callbackId.Value);
            }
            else if (!string.IsNullOrWhiteSpace(reference))
            {
                query.Criteria.AddCondition("pwrp_name", ConditionOperator.Equal, reference);
            }
            else if (!string.IsNullOrWhiteSpace(phoneNumber))
            {
                // No queue here: a caller looking up a callback gives a number and nothing
                // else. The organisation default is the best available guess, and a lookup
                // that misses is harmless where a booking against the wrong number is not.
                var phone = PhoneNumberValidator.Validate(phoneNumber, _config.GetString(ConfigKeys.DefaultCountryCode, "31"));
                query.Criteria.AddCondition("pwrp_phonenumber", ConditionOperator.Equal, phone.E164 ?? phoneNumber);
            }
            else
            {
                throw new ToolkitException(ErrorCodes.InvalidInput, "Supply a reference, a phone number, or a callback id.");
            }

            var found = _service.RetrieveMultiple(query).Entities.FirstOrDefault();
            if (found == null)
            {
                throw new ToolkitException(ErrorCodes.CallbackNotFound, "No callback found.");
            }

            return Map(found);
        }

        public CallbackRecord Cancel(Guid callbackId)
        {
            var record = new Entity("pwrp_callbackrequest", callbackId)
            {
                ["pwrp_status"] = new OptionSetValue(5) // Cancelled
            };
            _service.Update(record);
            return GetStatus(null, null, callbackId);
        }

        public CallbackRecord Reschedule(QueueRef queue, Guid callbackId, DateTime newStartUtc)
        {
            var slots = GetSlots(queue, DateTime.UtcNow, 14);
            if (slots.All(s => s.StartUtc != newStartUtc))
            {
                throw new ToolkitException(ErrorCodes.CallbackSlotUnavailable, "That time is not available.");
            }

            _service.Update(new Entity("pwrp_callbackrequest", callbackId)
            {
                ["pwrp_requestedstart"] = newStartUtc,
                ["pwrp_status"] = new OptionSetValue(1)
            });

            return GetStatus(null, null, callbackId);
        }

        private CallbackRecord FindOpen(Guid queueId, string e164)
        {
            var query = new QueryExpression("pwrp_callbackrequest")
            {
                ColumnSet = new ColumnSet("pwrp_name", "pwrp_phonenumber", "pwrp_queueid", "pwrp_mode", "pwrp_status", "pwrp_attempts", "pwrp_requestedstart"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("pwrp_queueid", ConditionOperator.Equal, queueId),
                        new ConditionExpression("pwrp_phonenumber", ConditionOperator.Equal, e164),
                        new ConditionExpression("pwrp_status", ConditionOperator.In, 1, 2, 3)
                    }
                },
                TopCount = 1
            };

            var found = _service.RetrieveMultiple(query).Entities.FirstOrDefault();
            return found == null ? null : Map(found);
        }

        private static CallbackRecord Map(Entity e)
        {
            return new CallbackRecord
            {
                CallbackId = e.Id,
                Reference = e.GetAttributeValue<string>("pwrp_name"),
                PhoneNumber = e.GetAttributeValue<string>("pwrp_phonenumber"),
                QueueId = e.GetAttributeValue<EntityReference>("pwrp_queueid")?.Id ?? Guid.Empty,
                Mode = e.GetAttributeValue<OptionSetValue>("pwrp_mode")?.Value == 2 ? "Scheduled" : "Direct",
                ScheduledStartUtc = e.GetAttributeValue<DateTime?>("pwrp_requestedstart"),
                Status = StatusName(e.GetAttributeValue<OptionSetValue>("pwrp_status")?.Value ?? 1),
                Attempts = e.GetAttributeValue<int>("pwrp_attempts")
            };
        }

        private static string StatusName(int value)
        {
            switch (value)
            {
                case 1: return "Requested";
                case 2: return "Queued";
                case 3: return "Dialling";
                case 4: return "Completed";
                case 5: return "Cancelled";
                case 6: return "Failed";
                case 7: return "NoAnswer";
                default: return "Unknown";
            }
        }

        private int SlotCapacity(QueueRef queue)
        {
            if (!queue.ProfileId.HasValue) return 5;
            var profile = _service.Retrieve("pwrp_queueprofile", queue.ProfileId.Value, new ColumnSet("pwrp_slotcapacity"));
            var value = profile.GetAttributeValue<int>("pwrp_slotcapacity");
            return value > 0 ? value : 5;
        }

        private Dictionary<DateTime, int> BookedPerSlot(Guid queueId, DateTime fromUtc, DateTime toUtc)
        {
            var query = new QueryExpression("pwrp_callbackrequest")
            {
                ColumnSet = new ColumnSet("pwrp_requestedstart"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("pwrp_queueid", ConditionOperator.Equal, queueId),
                        new ConditionExpression("pwrp_requestedstart", ConditionOperator.OnOrAfter, fromUtc),
                        new ConditionExpression("pwrp_requestedstart", ConditionOperator.OnOrBefore, toUtc),
                        new ConditionExpression("pwrp_status", ConditionOperator.In, 1, 2, 3)
                    }
                }
            };

            return _service.RetrieveMultiple(query).Entities
                .Select(e => e.GetAttributeValue<DateTime?>("pwrp_requestedstart"))
                .Where(d => d.HasValue)
                .GroupBy(d => d.Value)
                .ToDictionary(g => g.Key, g => g.Count());
        }

        private static string NewReference()
        {
            // Short, speakable, unambiguous over the phone. No letters that sound alike.
            const string alphabet = "3479ACEFHJKLMNPRTVWXY";
            var random = new Random(Guid.NewGuid().GetHashCode());
            return new string(Enumerable.Range(0, 6).Select(_ => alphabet[random.Next(alphabet.Length)]).ToArray());
        }
    }
}
