using System;
using System.Linq;

namespace PowerPete.IvrToolkit.Speech
{
    /// <summary>
    /// Speech recognition produces dirty numbers: spaces, spoken "plus", leading zeros,
    /// country prefixes both ways. Normalise to E.164 before anything writes a callback.
    /// Dutch rules are built in because that is where this gets used first. Other countries
    /// fall back to a length check, which is honest rather than wrong.
    /// </summary>
    public static class PhoneNumberValidator
    {
        public class Result
        {
            public bool IsValid;
            public string E164;
            public string NumberType;   // Mobile, Landline, Unknown
            public string Country;
            public string Reason;
        }

        public static Result Validate(string raw, string defaultCountryCode)
        {
            var result = new Result { NumberType = "Unknown", Country = defaultCountryCode };

            if (string.IsNullOrWhiteSpace(raw))
            {
                result.Reason = "Empty input.";
                return result;
            }

            var digits = new string(raw.Where(char.IsDigit).ToArray());
            var hadPlus = raw.TrimStart().StartsWith("+") || raw.IndexOf("00", StringComparison.Ordinal) == 0;

            if (digits.Length < 6)
            {
                result.Reason = "Too few digits.";
                return result;
            }

            // 00 prefix means international. Strip it and treat what follows as a country code.
            if (digits.StartsWith("00"))
            {
                digits = digits.Substring(2);
                hadPlus = true;
            }

            var cc = (defaultCountryCode ?? "31").TrimStart('+');

            if (!hadPlus && digits.StartsWith("0"))
            {
                digits = cc + digits.Substring(1);
            }
            else if (!hadPlus && !digits.StartsWith(cc))
            {
                digits = cc + digits;
            }

            if (digits.StartsWith("31"))
            {
                var national = digits.Substring(2);
                if (national.Length != 9)
                {
                    result.Reason = "A Dutch number needs nine digits after the country code.";
                    return result;
                }
                result.NumberType = national.StartsWith("6") ? "Mobile" : "Landline";
                result.Country = "NL";
            }
            else if (digits.Length < 8 || digits.Length > 15)
            {
                result.Reason = "Length is outside the E.164 range.";
                return result;
            }

            result.IsValid = true;
            result.E164 = "+" + digits;
            return result;
        }
    }
}
