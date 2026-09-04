using System;

namespace PowerPete.IvrToolkit.Common
{
    /// <summary>
    /// Error codes returned to the calling agent. Stable across versions.
    /// A voice agent branches on the code, never on the message text.
    /// </summary>
    public static class ErrorCodes
    {
        public const string QueueNotFound = "QUEUE_NOT_FOUND";
        public const string QueueAmbiguous = "QUEUE_AMBIGUOUS";
        public const string HoursNotConfigured = "HOURS_NOT_CONFIGURED";
        public const string MetricsUnavailable = "METRICS_UNAVAILABLE";
        public const string CallbackDisabled = "CALLBACK_DISABLED";
        public const string CallbackSlotUnavailable = "CALLBACK_SLOT_UNAVAILABLE";
        public const string CallbackNotFound = "CALLBACK_NOT_FOUND";
        public const string DuplicateCallback = "DUPLICATE_CALLBACK";
        public const string InvalidPhoneNumber = "INVALID_PHONE_NUMBER";
        public const string InvalidInput = "INVALID_INPUT";
        public const string ConfigurationError = "CONFIGURATION_ERROR";
    }

    /// <summary>
    /// Thrown for expected, caller-recoverable conditions. Never surfaces a stack trace.
    /// </summary>
    public class ToolkitException : Exception
    {
        public string Code { get; }

        public ToolkitException(string code, string message) : base(message)
        {
            Code = code;
        }
    }
}
