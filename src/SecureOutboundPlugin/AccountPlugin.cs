using System;
using Dataverse.SecureOutbound.Models;
using Dataverse.SecureOutbound.Plugins;
using Dataverse.SecureOutbound.Services;
using Microsoft.Xrm.Sdk;

namespace Dataverse.SecureOutbound
{
    /// <summary>
    /// Two-pillar "secure outbound" demo. Driven by two independent boolean fields on the Account,
    /// both writing their result to a single text field (<c>adc_result</c>):
    /// - <c>adc_usekeyvault</c> = read a secret from Key Vault via Managed Identity (Identity pillar).
    /// - <c>adc_usefunction</c> = call a private Function App (Network pillar).
    /// The two paths are fully decoupled - the Function call no longer borrows a token from Key Vault.
    /// Each environment makes one path succeed and the other fail (the failure is the demo punchline,
    /// surfaced as a clear message in the Plugin Trace Log).
    /// </summary>
    public sealed class AccountPlugin : PluginBase
    {
        private const string EnvVarKeyVaultUrl = "adc_KeyVaultUrl";
        private const string EnvVarSecretName = "adc_KeyVaultAccountSecretName";
        private const string EnvVarErpApiUrl = "adc_ErpApiUrl";

        private const string UseKeyVaultField = "adc_usekeyvault";
        private const string UseFunctionField = "adc_usefunction";
        private const string ResultField = "adc_result";

        // The Function path is decoupled from Key Vault; in this demo the boundary being shown is the
        // network (private endpoint), so a placeholder bearer token is enough to satisfy the endpoint.
        private const string DemoBearerToken = "demo-token";

        private readonly Func<LocalPluginContext, IEnvironmentVariableValueProvider> _environmentVariableServiceFactory;
        private readonly Func<LocalPluginContext, ISecretService> _secretServiceFactory;
        private readonly Func<LocalPluginContext, IErpService> _erpServiceFactory;

        public AccountPlugin()
            : this(
                localContext => new EnvironmentVariableService(localContext.UserService, localContext.TracingService),
                localContext => new KeyVaultSecretService(localContext.TracingService, localContext.ManagedIdentityService),
                localContext => new ErpService(localContext.TracingService))
        {
        }

        internal AccountPlugin(
            Func<LocalPluginContext, IEnvironmentVariableValueProvider> environmentVariableServiceFactory,
            Func<LocalPluginContext, ISecretService> secretServiceFactory,
            Func<LocalPluginContext, IErpService> erpServiceFactory)
            : base(typeof(AccountPlugin))
        {
            _environmentVariableServiceFactory = environmentVariableServiceFactory ?? throw new ArgumentNullException(nameof(environmentVariableServiceFactory));
            _secretServiceFactory = secretServiceFactory ?? throw new ArgumentNullException(nameof(secretServiceFactory));
            _erpServiceFactory = erpServiceFactory ?? throw new ArgumentNullException(nameof(erpServiceFactory));
        }

        protected override void ExecutePlugin(LocalPluginContext localContext)
        {
            Entity target = localContext.GetTargetEntity();
            if (!ShouldRun(localContext, target, out bool useKeyVault, out bool useFunction))
            {
                return;
            }

            Guid accountId = localContext.PluginExecutionContext.PrimaryEntityId;
            localContext.Trace("Target Account Id: {0}. UseKeyVault={1}, UseFunction={2}.",
                accountId, useKeyVault, useFunction);

            SecureOutboundSettings settings = ReadSettings(localContext, _environmentVariableServiceFactory(localContext));

            // Independent branches. If both booleans are set, run Key Vault first then the Function,
            // so the Function result is what lands in adc_result.
            if (useKeyVault)
            {
                RunKeyVaultPath(localContext, accountId, settings);
            }

            if (useFunction)
            {
                RunFunctionPath(localContext, accountId, settings);
            }
        }

        private static bool ShouldRun(
            LocalPluginContext localContext,
            Entity target,
            out bool useKeyVault,
            out bool useFunction)
        {
            useKeyVault = false;
            useFunction = false;

            if (!string.Equals(localContext.MessageName, "Update", StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(localContext.PrimaryEntityName, "account", StringComparison.OrdinalIgnoreCase))
            {
                localContext.Trace("Not an Account Update, skipping.");
                return false;
            }

            if (target == null)
            {
                localContext.Trace("No Target entity, skipping.");
                return false;
            }

            useKeyVault = target.Contains(UseKeyVaultField) && target.GetAttributeValue<bool>(UseKeyVaultField);
            useFunction = target.Contains(UseFunctionField) && target.GetAttributeValue<bool>(UseFunctionField);

            if (!useKeyVault && !useFunction)
            {
                localContext.Trace(
                    "Neither '{0}' nor '{1}' is set to true in the Target - nothing to do. " +
                    "Tick a box and save to run the demo.",
                    UseKeyVaultField, UseFunctionField);
                return false;
            }

            return true;
        }

        private void RunKeyVaultPath(LocalPluginContext localContext, Guid accountId, SecureOutboundSettings settings)
        {
            localContext.Trace("=== Key Vault path (Identity pillar) ===");
            string keyVaultUrl = RequireSetting(settings.KeyVaultUrl, EnvVarKeyVaultUrl);
            string secretName = RequireSetting(settings.SecretName, EnvVarSecretName);

            ISecretService secretService = _secretServiceFactory(localContext);
            string secretValue = secretService.GetSecret(keyVaultUrl, secretName);
            WriteResult(localContext, accountId, secretValue);
            localContext.Trace("Account field '{0}' updated from Key Vault secret.", ResultField);
        }

        private void RunFunctionPath(LocalPluginContext localContext, Guid accountId, SecureOutboundSettings settings)
        {
            localContext.Trace("=== Function App path (Network pillar) ===");
            string erpApiUrl = RequireSetting(settings.ErpApiUrl, EnvVarErpApiUrl);

            Entity account = GetAccountFromPostImage(localContext);
            IErpService erpService = _erpServiceFactory(localContext);
            string erpNumber = erpService.SyncAccount(erpApiUrl, DemoBearerToken, account);
            WriteResult(localContext, accountId, erpNumber);
            localContext.Trace("Account field '{0}' updated from Function App response.", ResultField);
        }

        private static SecureOutboundSettings ReadSettings(
            LocalPluginContext localContext,
            IEnvironmentVariableValueProvider environmentVariableService)
        {
            localContext.Trace("Reading Environment Variables.");

            string keyVaultUrl = Clean(environmentVariableService.GetValue(EnvVarKeyVaultUrl));
            string secretName = Clean(environmentVariableService.GetValue(EnvVarSecretName));
            string erpApiUrl = Clean(environmentVariableService.GetValue(EnvVarErpApiUrl));

            localContext.Trace("Settings loaded. Vault='{0}', Secret='{1}', ERP='{2}'.",
                Display(keyVaultUrl), Display(secretName), Display(erpApiUrl));

            return new SecureOutboundSettings(keyVaultUrl, secretName, erpApiUrl);
        }

        private static string Clean(string value) =>
            string.IsNullOrWhiteSpace(value) ? string.Empty : value.Trim();

        private static string Display(string value) =>
            string.IsNullOrWhiteSpace(value) ? "(not set)" : value;

        private static string RequireSetting(string value, string schemaName)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }

            throw new InvalidPluginExecutionException(
                $"Environment Variable '{schemaName}' is missing or empty.");
        }

        private static void WriteResult(LocalPluginContext localContext, Guid accountId, string value)
        {
            Entity update = new Entity("account", accountId);
            update[ResultField] = value;
            localContext.SystemService.Update(update);
        }

        private static Entity GetAccountFromPostImage(LocalPluginContext localContext)
        {
            Entity postImage = localContext.GetFirstPostImage();
            if (postImage == null)
            {
                throw new InvalidPluginExecutionException(
                    "No Post-Image is registered. Please configure one with at least: accountid, name, adc_crmnumber.");
            }

            localContext.Trace("Using Account data from first available Post-Image.");
            return postImage;
        }
    }
}
