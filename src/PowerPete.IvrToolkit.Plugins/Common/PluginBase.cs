using System;
using System.Diagnostics;
using Microsoft.Xrm.Sdk;

namespace PowerPete.IvrToolkit.Common
{
    /// <summary>
    /// Base class for every Custom API in the toolkit.
    ///
    /// Contract rules that every endpoint follows:
    ///  - Success and expected failure both return HTTP 200 with Success = false plus an ErrorCode.
    ///    A voice agent must never see a raw platform fault.
    ///  - Every response carries a Speakable string alongside the structured payload.
    ///  - Every execution logs duration so latency regressions are visible.
    /// </summary>
    public abstract class ToolkitPluginBase : IPlugin
    {
        public void Execute(IServiceProvider serviceProvider)
        {
            var context = (IPluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));
            var tracing = (ITracingService)serviceProvider.GetService(typeof(ITracingService));
            var factory = (IOrganizationServiceFactory)serviceProvider.GetService(typeof(IOrganizationServiceFactory));
            var service = factory.CreateOrganizationService(context.UserId);

            var stopwatch = Stopwatch.StartNew();
            var request = new ToolkitRequest(context, service, tracing, new ConfigReader(service));

            try
            {
                Handle(request);
                SetOutput(context, "Success", true);
                SetOutput(context, "ErrorCode", string.Empty);
                SetOutput(context, "ErrorMessage", string.Empty);
            }
            catch (ToolkitException known)
            {
                tracing.Trace("Handled: {0} - {1}", known.Code, known.Message);
                SetOutput(context, "Success", false);
                SetOutput(context, "ErrorCode", known.Code);
                SetOutput(context, "ErrorMessage", known.Message);
            }
            catch (Exception unexpected)
            {
                tracing.Trace("Unhandled: {0}", unexpected);
                SetOutput(context, "Success", false);
                SetOutput(context, "ErrorCode", "UNEXPECTED_ERROR");
                SetOutput(context, "ErrorMessage", "The toolkit could not complete the request.");
            }
            finally
            {
                stopwatch.Stop();
                tracing.Trace("[pwrp] {0} completed in {1} ms", context.MessageName, stopwatch.ElapsedMilliseconds);
                SetOutput(context, "DurationMs", (int)stopwatch.ElapsedMilliseconds);
            }
        }

        protected abstract void Handle(ToolkitRequest request);

        private static void SetOutput(IPluginExecutionContext context, string key, object value)
        {
            context.OutputParameters[key] = value;
        }
    }

    /// <summary>Everything an endpoint needs, passed as one object.</summary>
    public class ToolkitRequest
    {
        public IPluginExecutionContext Context { get; }
        public IOrganizationService Service { get; }
        public ITracingService Tracing { get; }
        public ConfigReader Config { get; }

        public ToolkitRequest(IPluginExecutionContext context, IOrganizationService service, ITracingService tracing, ConfigReader config)
        {
            Context = context;
            Service = service;
            Tracing = tracing;
            Config = config;
        }

        public string GetString(string name, string fallback = null)
        {
            return Context.InputParameters.Contains(name) && Context.InputParameters[name] is string value && !string.IsNullOrWhiteSpace(value)
                ? value.Trim()
                : fallback;
        }

        public string RequireString(string name)
        {
            var value = GetString(name);
            if (value == null)
            {
                throw new ToolkitException(ErrorCodes.InvalidInput, $"Input '{name}' is required.");
            }
            return value;
        }

        public int GetInt(string name, int fallback)
        {
            return Context.InputParameters.Contains(name) && Context.InputParameters[name] is int value ? value : fallback;
        }

        public bool GetBool(string name, bool fallback)
        {
            return Context.InputParameters.Contains(name) && Context.InputParameters[name] is bool value ? value : fallback;
        }

        /// <summary>Reads an optional DateTime input, treating an unsupplied one as null.</summary>
        /// <remarks>
        /// An optional DateTime that the caller omitted does not arrive absent. Dataverse
        /// puts default(DateTime) in the collection instead, so Contains returns true and a
        /// "?? DateTime.UtcNow" fallback in the caller never fires. That is how GetQueueHours
        /// came to answer for the week beginning 1 January 0001. Year one means unsupplied.
        /// </remarks>
        public DateTime? GetDate(string name)
        {
            if (Context.InputParameters.Contains(name) && Context.InputParameters[name] is DateTime value)
            {
                return value == DateTime.MinValue ? (DateTime?)null : value;
            }
            var raw = GetString(name);
            return DateTime.TryParse(raw, out var parsed) ? parsed : (DateTime?)null;
        }

        public void SetOutput(string name, object value)
        {
            Context.OutputParameters[name] = value;
        }
    }
}
