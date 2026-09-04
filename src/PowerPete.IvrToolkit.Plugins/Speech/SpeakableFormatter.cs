using System;
using System.Collections.Generic;
using System.Linq;
using PowerPete.IvrToolkit.Model;

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
                ["callback_queued"] = "We bellen u terug op {number} zodra er een medewerker vrij is."
            },
            ["en-GB"] = new Dictionary<string, string>
            {
                ["open_now"] = "We are open now until {close}.",
                ["closed_next"] = "We are closed right now. We open again {next}.",
                ["closed_indefinite"] = "We are closed right now.",
                ["holiday"] = "We are closed today for a public holiday.",
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
                ["callback_queued"] = "We will call you back on {number} as soon as someone is free."
            }
        };

        private static string S(string locale, string key)
        {
            var table = Strings.ContainsKey(locale ?? string.Empty) ? Strings[locale] : Strings["en-GB"];
            return table.ContainsKey(key) ? table[key] : Strings["en-GB"][key];
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
                return S(locale, "holiday");
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
