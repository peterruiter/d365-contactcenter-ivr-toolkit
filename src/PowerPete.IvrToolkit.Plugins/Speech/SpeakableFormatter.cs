using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Common;
using PowerPete.IvrToolkit.Model;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace PowerPete.IvrToolkit.Speech
{
    /// <summary>
    /// Every endpoint returns structured data plus a speakable string.
    ///
    /// This is the part clients rebuild badly every time. A voice agent reading
    /// "09:00:00 - 17:30:00" out loud sounds like a machine. Times are spoken the way a
    /// person says them, in the queue locale, with relative day names where they help.
    ///
    /// Templates live in code with a resource override in pwrp_messagetemplate, so a client
    /// can adjust wording without a code change.
    /// </summary>
    public static class SpeakableFormatter
    {
        private static readonly Dictionary<string, Dictionary<string, string>> Strings =
            new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase)
        {
            ["nl-NL"] = new Dictionary<string, string>
            {
                ["open_now"] = "We zijn nu open tot {close}.",
                ["closed_next"] = "We zijn nu gesloten. We zijn weer open {next}.",
                ["closed_indefinite"] = "We zijn nu gesloten.",
                ["holiday"] = "We zijn vandaag gesloten in verband met een feestdag.",
                ["holiday_named"] = "We zijn vandaag gesloten in verband met {holiday}.",
                ["day_open"] = "{day} van {windows}",
                ["day_closed"] = "{day} gesloten",
                ["wait_short"] = "U wordt zo geholpen.",
                ["wait_moderate"] = "De wachttijd is op dit moment een paar minuten.",
                ["wait_long"] = "De wachttijd is op dit moment langer dan normaal.",
                ["wait_verylong"] = "Het is nu erg druk en de wachttijd is lang.",
                ["today"] = "vandaag",
                ["tomorrow"] = "morgen",
                ["at"] = "om",
                ["and"] = "en",
                ["callback_booked"] = "We bellen u terug {when} op {number}.",
                ["callback_queued"] = "We bellen u terug op {number} zodra er een medewerker vrij is.",
                ["callback_slot"] = "{when}"
            },
            ["en-GB"] = new Dictionary<string, string>
            {
                ["open_now"] = "We are open now until {close}.",
                ["closed_next"] = "We are closed right now. We open again {next}.",
                ["closed_indefinite"] = "We are closed right now.",
                ["holiday"] = "We are closed today for a public holiday.",
                ["holiday_named"] = "We are closed today for {holiday}.",
                ["day_open"] = "{day} from {windows}",
                ["day_closed"] = "{day} closed",
                ["wait_short"] = "You will be connected shortly.",
                ["wait_moderate"] = "The wait is a few minutes at the moment.",
                ["wait_long"] = "The wait is longer than usual at the moment.",
                ["wait_verylong"] = "It is very busy and the wait is long.",
                ["today"] = "today",
                ["tomorrow"] = "tomorrow",
                ["at"] = "at",
                ["and"] = "and",
                ["callback_booked"] = "We will call you back {when} on {number}.",
                ["callback_queued"] = "We will call you back on {number} as soon as someone is free.",
                ["callback_slot"] = "{when}"
            }
        };

        /// <summary>
        /// Wording from pwrp_messagetemplate, keyed by "locale|key". Replaced wholesale
        /// rather than mutated, so a read is never half updated.
        /// </summary>
        private static volatile Dictionary<string, string> _overrides = new Dictionary<string, string>();

        /// <summary>
        /// Loads the wording overrides. Call once per request, before formatting anything.
        /// </summary>
        /// <remarks>
        /// This table was created, seeded, put on the app and documented as the way to
        /// change wording without a deployment, and until now nothing read it. Every
        /// override silently did nothing.
        /// </remarks>
        public static void LoadOverrides(IOrganizationService service, ConfigReader config)
        {
            var ttl = config.GetInt(ConfigKeys.HoursCacheSeconds, 300);

            _overrides = CacheStore.GetOrAdd("templates:all", ttl, () =>
            {
                var loaded = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

                var query = new QueryExpression("pwrp_messagetemplate")
                {
                    ColumnSet = new ColumnSet("pwrp_name", "pwrp_locale", "pwrp_text"),
                    Criteria = { Conditions = { new ConditionExpression("statecode", ConditionOperator.Equal, 0) } }
                };

                foreach (var row in service.RetrieveMultiple(query).Entities)
                {
                    var key = row.GetAttributeValue<string>("pwrp_name");
                    var locale = row.GetAttributeValue<string>("pwrp_locale");
                    var text = row.GetAttributeValue<string>("pwrp_text");
                    if (string.IsNullOrWhiteSpace(key) || string.IsNullOrWhiteSpace(text)) continue;

                    loaded[(locale ?? "en-GB").Trim() + "|" + key.Trim()] = text;
                }

                return loaded;
            });
        }

        /// <summary>
        /// A phrase, most specific first: an override for this locale, an override for
        /// en-GB, the built in phrase for this locale, then the built in English.
        /// </summary>
        private static string S(string locale, string key)
        {
            var overrides = _overrides;
            string custom;
            if (overrides.TryGetValue((locale ?? "en-GB") + "|" + key, out custom)) return custom;
            if (overrides.TryGetValue("en-GB|" + key, out custom)) return custom;

            var table = Strings.ContainsKey(locale ?? string.Empty) ? Strings[locale] : Strings["en-GB"];
            return table.ContainsKey(key) ? table[key] : Strings["en-GB"][key];
        }

        /// <summary>Every key that can be overridden, for documentation and validation.</summary>
        public static IEnumerable<string> Keys
        {
            get { return Strings["en-GB"].Keys; }
        }

        public static string DescribeDay(DayHours day, string locale)
        {
            var dayName = day.Date.ToString("dddd", Culture(locale));

            if (!day.IsOpen)
            {
                return S(locale, "day_closed").Replace("{day}", dayName);
            }

            var windows = string.Join(" " + S(locale, "and") + " ",
                day.Windows.Select(w => $"{Time(w.StartLocal, locale)} - {Time(w.EndLocal, locale)}"));

            return S(locale, "day_open").Replace("{day}", dayName).Replace("{windows}", windows);
        }

        public static string DescribeOpenState(OpenState state, QueueRef queue, TimeZoneInfo tz)
        {
            var locale = queue.Locale;

            if (state.IsOpen && state.NextCloseUtc.HasValue)
            {
                var close = TimeZoneInfo.ConvertTimeFromUtc(state.NextCloseUtc.Value, tz);
                return S(locale, "open_now").Replace("{close}", Time(close, locale));
            }

            if (state.Reason == "Holiday")
            {
                // The unnamed line stays for the source that cannot name a holiday. Native
                // operating hours do not distinguish one, and a name is optional on a
                // config row, so "closed for a public holiday" has to remain sayable.
                return string.IsNullOrWhiteSpace(state.HolidayName)
                    ? S(locale, "holiday")
                    : S(locale, "holiday_named").Replace("{holiday}", state.HolidayName);
            }

            if (!state.NextOpenUtc.HasValue)
            {
                return S(locale, "closed_indefinite");
            }

            var next = TimeZoneInfo.ConvertTimeFromUtc(state.NextOpenUtc.Value, tz);
            var nowLocal = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, tz);
            return S(locale, "closed_next").Replace("{next}", RelativeDayTime(next, nowLocal, locale));
        }

        public static string DescribeWait(string band, string locale)
        {
            switch (band)
            {
                case "Short": return S(locale, "wait_short");
                case "Moderate": return S(locale, "wait_moderate");
                case "Long": return S(locale, "wait_long");
                default: return S(locale, "wait_verylong");
            }
        }

        /// <summary>
        /// A slot on offer, before the caller has given a number.
        /// </summary>
        /// <remarks>
        /// Not DescribeCallback with an empty number. That renders "We will call you back
        /// today at 12:00 on ." and reads aloud as a sentence that stops mid word. A slot
        /// is a time being offered, not a booking being confirmed, so it is its own phrase.
        ///
        /// The template is just {when} because three of these are read in a row. Anything
        /// longer is said three times and the caller has stopped listening by the second.
        /// </remarks>
        public static string DescribeSlot(DateTime whenLocal, string locale)
        {
            return S(locale, "callback_slot")
                .Replace("{when}", RelativeDayTime(whenLocal, DateTime.Now, locale));
        }

        public static string DescribeCallback(DateTime? whenLocal, string number, string locale)
        {
            var spokenNumber = SpellNumber(number);

            if (!whenLocal.HasValue)
            {
                return S(locale, "callback_queued").Replace("{number}", spokenNumber);
            }

            var nowLocal = DateTime.Now;
            return S(locale, "callback_booked")
                .Replace("{when}", RelativeDayTime(whenLocal.Value, nowLocal, locale))
                .Replace("{number}", spokenNumber);
        }

        private static string RelativeDayTime(DateTime target, DateTime now, string locale)
        {
            var dayPart = target.Date == now.Date ? S(locale, "today")
                : target.Date == now.Date.AddDays(1) ? S(locale, "tomorrow")
                : target.ToString("dddd", Culture(locale));

            return $"{dayPart} {S(locale, "at")} {Time(target, locale)}";
        }

        /// <summary>08:30 becomes "half nine" style noise if you let TTS guess. Keep it explicit.</summary>
        private static string Time(DateTime value, string locale)
        {
            return value.Minute == 0
                ? value.ToString("HH:00", Culture(locale))
                : value.ToString("HH:mm", Culture(locale));
        }

        /// <summary>Digits read one at a time so a confirmation is actually verifiable.</summary>
        public static string SpellNumber(string number)
        {
            if (string.IsNullOrWhiteSpace(number)) return string.Empty;
            return string.Join(" ", number.Where(char.IsDigit).Select(c => c.ToString()));
        }

        private static System.Globalization.CultureInfo Culture(string locale)
        {
            try
            {
                return new System.Globalization.CultureInfo(locale ?? "en-GB");
            }
            catch (Exception)
            {
                return new System.Globalization.CultureInfo("en-GB");
            }
        }
    }
}
