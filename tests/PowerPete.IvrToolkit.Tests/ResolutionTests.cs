using PowerPete.IvrToolkit.Metrics;
using PowerPete.IvrToolkit.Queues;
using PowerPete.IvrToolkit.Speech;
using Xunit;

namespace PowerPete.IvrToolkit.Tests
{
    /// <summary>
    /// These cover the parts that break in production: dirty speech input and
    /// banding thresholds. The Dataverse query paths are covered by integration
    /// tests against a real environment, because faking msdyn_queueextension
    /// would only test the fake.
    /// </summary>
    public class ResolutionTests
    {
        [Theory]
        [InlineData("klantenservice", "klantenservice", 100)]
        [InlineData("klanten service", "klantenservice", 90)]
        [InlineData("klantenservise", "klantenservice", 85)]
        public void Similarity_handles_speech_noise(string spoken, string actual, int minimum)
        {
            Assert.True(QueueResolver.Similarity(spoken, actual) >= minimum);
        }

        [Theory]
        [InlineData(30, "Short")]
        [InlineData(60, "Short")]
        [InlineData(120, "Moderate")]
        [InlineData(300, "Long")]
        [InlineData(900, "VeryLong")]
        public void Bands_map_to_thresholds(int seconds, string expected)
        {
            Assert.Equal(expected, WaitBandCalculator.Band(seconds, "60,180,420"));
        }

        [Fact]
        public void Bands_fall_back_when_config_is_broken()
        {
            Assert.Equal("Short", WaitBandCalculator.Band(30, "nonsense"));
        }
    }

    public class PhoneNumberTests
    {
        [Theory]
        [InlineData("06 12 34 56 78", "+31612345678", "Mobile")]
        [InlineData("0612345678", "+31612345678", "Mobile")]
        [InlineData("+31 6 1234 5678", "+31612345678", "Mobile")]
        [InlineData("0031612345678", "+31612345678", "Mobile")]
        [InlineData("020 123 4567", "+31201234567", "Landline")]
        public void Dutch_numbers_normalise_to_e164(string raw, string expected, string type)
        {
            var result = PhoneNumberValidator.Validate(raw, "31");
            Assert.True(result.IsValid, result.Reason);
            Assert.Equal(expected, result.E164);
            Assert.Equal(type, result.NumberType);
        }

        [Theory]
        [InlineData("12345")]
        [InlineData("")]
        [InlineData("06 1234")]
        public void Bad_input_is_rejected_with_a_reason(string raw)
        {
            var result = PhoneNumberValidator.Validate(raw, "31");
            Assert.False(result.IsValid);
            Assert.False(string.IsNullOrWhiteSpace(result.Reason));
        }

        [Fact]
        public void Numbers_are_spelled_digit_by_digit_for_confirmation()
        {
            Assert.Equal("3 1 6 1 2 3 4 5 6 7 8", SpeakableFormatter.SpellNumber("+31612345678"));
        }

        /// <summary>
        /// A tool configuration cannot leave an optional input out, so makers type a
        /// placeholder. "-" reached production and became the dialling prefix: the caller
        /// said 0653740141, the toolkit answered "+-653740141" with IsValid true, and that
        /// is what was written to the callback.
        /// </summary>
        [Theory]
        [InlineData("-")]
        [InlineData("")]
        [InlineData("  ")]
        [InlineData("n/a")]
        [InlineData("none")]
        [InlineData("+")]
        [InlineData("1234")]
        public void Country_code_that_cannot_be_one_is_ignored(string junk)
        {
            Assert.Null(PhoneNumberValidator.NormaliseCountryCode(junk));

            // Falls back rather than failing, so a bad tool configuration does not cost
            // the caller their callback.
            var result = PhoneNumberValidator.Validate("0653740141", junk);
            Assert.True(result.IsValid);
            Assert.Equal("+31653740141", result.E164);
        }

        [Theory]
        [InlineData("31", "31")]
        [InlineData("+31", "31")]
        [InlineData(" 32 ", "32")]
        [InlineData("1", "1")]
        public void A_real_country_code_is_kept(string raw, string expected)
        {
            Assert.Equal(expected, PhoneNumberValidator.NormaliseCountryCode(raw));
        }

        [Fact]
        public void A_belgian_queue_does_not_get_a_dutch_number()
        {
            var result = PhoneNumberValidator.Validate("0475 123456", "32");
            Assert.True(result.IsValid);
            Assert.Equal("+32475123456", result.E164);
        }

        [Fact]
        public void Every_valid_number_normalises_to_digits()
        {
            var result = PhoneNumberValidator.Validate("06 53 74 01 41", "31");
            Assert.True(result.IsValid);
            Assert.StartsWith("+", result.E164);
            Assert.All(result.E164.Substring(1), c => Assert.True(char.IsDigit(c)));
        }
    }
}
