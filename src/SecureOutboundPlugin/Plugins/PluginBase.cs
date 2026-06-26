using System;
using System.ServiceModel;
using Microsoft.Xrm.Sdk;

namespace Dataverse.SecureOutbound.Plugins
{
    /// <summary>
    /// Common Dataverse plugin wrapper: creates <see cref="LocalPluginContext"/>, traces execution,
    /// and normalizes technical errors as <see cref="InvalidPluginExecutionException"/>.
    /// </summary>
    public abstract class PluginBase : IPlugin
    {
        /// <summary>Display name of the concrete plug-in, used in trace lines.</summary>
        protected string PluginClassName { get; }

        /// <summary>Initializes the base with the concrete plug-in's type for tracing.</summary>
        /// <param name="childClassType">The <c>typeof</c> the derived plug-in.</param>
        protected PluginBase(Type childClassType)
        {
            PluginClassName = (childClassType ?? GetType()).Name;
        }

        /// <summary>
        /// Platform entry point. Builds the context and hands off to <see cref="ExecutePlugin"/>.
        /// </summary>
        /// <param name="serviceProvider">Platform-supplied container of plug-in services.</param>
        public void Execute(IServiceProvider serviceProvider)
        {
            if (serviceProvider == null)
            {
                throw new ArgumentNullException(nameof(serviceProvider));
            }

            var localContext = new LocalPluginContext(serviceProvider);
            DateTime startUtc = DateTime.UtcNow;
            Guid correlationId = localContext.PluginExecutionContext.CorrelationId;
            Guid operationId = localContext.PluginExecutionContext.OperationId;

            localContext.Trace("{0}: Execute started. Message='{1}', Entity='{2}', Stage={3}, Mode={4}, Depth={5}.",
                PluginClassName,
                localContext.PluginExecutionContext.MessageName,
                localContext.PluginExecutionContext.PrimaryEntityName,
                localContext.PluginExecutionContext.Stage,
                localContext.PluginExecutionContext.Mode,
                localContext.PluginExecutionContext.Depth);

            try
            {
                ExecutePlugin(localContext);
                localContext.Trace("{0}: Execute completed.", PluginClassName);
            }
            catch (InvalidPluginExecutionException ex)
            {
                localContext.Trace("{0}: InvalidPluginExecutionException: {1}", PluginClassName, ex.ToString());
                throw;
            }
            catch (FaultException<OrganizationServiceFault> ex)
            {
                localContext.Trace("{0}: OrganizationServiceFault: {1}", PluginClassName, ex.ToString());
                throw new InvalidPluginExecutionException($"Technical error: {ex.Detail?.Message ?? ex.Message}", ex);
            }
            catch (Exception ex)
            {
                localContext.Trace("{0}: Exception: {1}", PluginClassName, ex.ToString());
                throw new InvalidPluginExecutionException($"Technical error: {ex.Message}", ex);
            }
            finally
            {
                TimeSpan elapsed = DateTime.UtcNow - startUtc;
                localContext.Trace(
                    "{0}: Execute finished. CorrelationId='{1}', OperationId='{2}', ElapsedMs={3}.",
                    PluginClassName,
                    correlationId,
                    operationId,
                    (int)elapsed.TotalMilliseconds);
            }
        }

        /// <summary>The plug-in's business logic. Implement this in the derived class.</summary>
        /// <param name="localContext">The prepared execution context.</param>
        protected abstract void ExecutePlugin(LocalPluginContext localContext);
    }
}
