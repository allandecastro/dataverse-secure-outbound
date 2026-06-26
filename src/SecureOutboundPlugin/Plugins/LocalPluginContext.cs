using System;
using Microsoft.Xrm.Sdk;

namespace Dataverse.SecureOutbound.Plugins
{
    /// <summary>
    /// Lightweight wrapper around Dataverse plugin services (context, tracing, org services, images).
    /// </summary>
    public sealed class LocalPluginContext
    {
        private IOrganizationService _systemService;
        private IOrganizationService _userService;

        /// <summary>Creates the context from the platform-supplied service provider.</summary>
        /// <param name="serviceProvider">The container passed to <c>IPlugin.Execute</c>.</param>
        public LocalPluginContext(IServiceProvider serviceProvider)
        {
            ServiceProvider = serviceProvider ?? throw new ArgumentNullException(nameof(serviceProvider));
            TracingService = (ITracingService)serviceProvider.GetService(typeof(ITracingService));
            PluginExecutionContext = (IPluginExecutionContext)serviceProvider.GetService(typeof(IPluginExecutionContext));
            ServiceFactory = (IOrganizationServiceFactory)serviceProvider.GetService(typeof(IOrganizationServiceFactory));
            ManagedIdentityService = (IManagedIdentityService)serviceProvider.GetService(typeof(IManagedIdentityService));
        }

        /// <summary>The raw service provider, for the rare case a plug-in needs something else.</summary>
        public IServiceProvider ServiceProvider { get; }

        /// <summary>The plug-in execution context (message, entity, stage, depth, parameters...).</summary>
        public IPluginExecutionContext PluginExecutionContext { get; }

        /// <summary>Writes to the Plugin Trace Log.</summary>
        public ITracingService TracingService { get; }

        /// <summary>Factory used to create org services as SYSTEM or as the calling user.</summary>
        public IOrganizationServiceFactory ServiceFactory { get; }

        /// <summary>Dataverse managed identity token service for outbound Azure access.</summary>
        public IManagedIdentityService ManagedIdentityService { get; }

        /// <summary>Org service running as SYSTEM (created lazily, cached).</summary>
        public IOrganizationService SystemService =>
            _systemService ?? (_systemService = ServiceFactory.CreateOrganizationService(null));

        /// <summary>Org service impersonating the calling user (created lazily, cached).</summary>
        public IOrganizationService UserService =>
            _userService ?? (_userService = ServiceFactory.CreateOrganizationService(PluginExecutionContext.UserId));

        /// <summary>The message name, e.g. "Update".</summary>
        public string MessageName => PluginExecutionContext.MessageName;

        /// <summary>The primary entity logical name, e.g. "account".</summary>
        public string PrimaryEntityName => PluginExecutionContext.PrimaryEntityName;

        /// <summary>The current execution depth (1 = direct, &gt;1 = triggered by another plug-in).</summary>
        public int Depth => PluginExecutionContext.Depth;

        /// <summary>Convenience pass-through to the tracing service.</summary>
        /// <param name="format">Composite format string.</param>
        /// <param name="args">Format arguments.</param>
        public void Trace(string format, params object[] args)
        {
            if (TracingService == null || string.IsNullOrEmpty(format))
            {
                return;
            }

            TracingService.Trace(args == null || args.Length == 0 ? format : string.Format(format, args));
        }

        /// <summary>
        /// Returns the <c>Target</c> input parameter as an <see cref="Entity"/> (Create/Update),
        /// or <c>null</c> if there isn't one of that type.
        /// </summary>
        public Entity GetTargetEntity()
        {
            return PluginExecutionContext.InputParameters.TryGetValue("Target", out var target) && target is Entity entity
                ? entity
                : null;
        }

        /// <summary>
        /// Returns the <c>Target</c> input parameter as an <see cref="EntityReference"/> (Delete),
        /// or <c>null</c> if there isn't one of that type.
        /// </summary>
        public EntityReference GetTargetEntityReference()
        {
            return PluginExecutionContext.InputParameters.TryGetValue("Target", out var target) && target is EntityReference reference
                ? reference
                : null;
        }

        /// <summary>Returns a registered pre-image by name, or <c>null</c> if absent.</summary>
        /// <param name="name">The image name configured on the step.</param>
        public Entity GetPreImage(string name)
        {
            return PluginExecutionContext.PreEntityImages.TryGetValue(name, out var image) ? image : null;
        }

        /// <summary>Returns a registered post-image by name, or <c>null</c> if absent.</summary>
        /// <param name="name">The image name configured on the step.</param>
        public Entity GetPostImage(string name)
        {
            return PluginExecutionContext.PostEntityImages.TryGetValue(name, out var image) ? image : null;
        }

        /// <summary>Returns the first registered post-image, or <c>null</c> if none is present.</summary>
        public Entity GetFirstPostImage()
        {
            foreach (var imageEntry in PluginExecutionContext.PostEntityImages)
            {
                return imageEntry.Value;
            }

            return null;
        }
    }
}
