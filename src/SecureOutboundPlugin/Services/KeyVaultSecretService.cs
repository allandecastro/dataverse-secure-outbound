using System;
using Azure;
using Azure.Core;
using Azure.Security.KeyVault.Secrets;
using Microsoft.Xrm.Sdk;

namespace Dataverse.SecureOutbound.Services
{
    /// <summary>
    /// Retrieves secrets from Azure Key Vault with Managed Identity.
    /// Reads are always live so secret updates are effective immediately.
    /// </summary>
    public sealed class KeyVaultSecretService : ISecretService
    {
        private const string KeyVaultScope = "https://vault.azure.net/.default";
        private readonly ITracingService _tracing;
        private readonly IManagedIdentityService _managedIdentityService;

        public KeyVaultSecretService(ITracingService tracing, IManagedIdentityService managedIdentityService)
        {
            _tracing = tracing ?? throw new ArgumentNullException(nameof(tracing));
            _managedIdentityService = managedIdentityService ?? throw new InvalidPluginExecutionException(
                "IManagedIdentityService is not available in the plugin execution context.");
        }

        /// <summary>
        /// Returns the named secret from Azure Key Vault.
        /// </summary>
        /// <param name="vaultUrl">The Key Vault base URL, e.g. https://myvault.vault.azure.net/.</param>
        /// <param name="secretName">The name of the secret to retrieve.</param>
        /// <returns>The secret's value as a string.</returns>
        public string GetSecret(string vaultUrl, string secretName)
        {
            _tracing.Trace("KeyVaultSecretService: get secret '{0}' from '{1}'.", secretName, vaultUrl);

            if (!Uri.TryCreate(vaultUrl, UriKind.Absolute, out var vaultUri))
            {
                throw new InvalidPluginExecutionException(
                    $"The Key Vault URL '{vaultUrl}' is not a valid absolute URL.");
            }

            return FetchFromKeyVault(vaultUri, secretName);
        }

        private string FetchFromKeyVault(Uri vaultUri, string secretName)
        {
            try
            {
                // Short network timeout + no retries: a healthy vault answers in well under a second,
                // but when the network path is blocked (e.g. the vault is 'outside' the injected VNet)
                // we want to fail FAST with a clear message instead of hanging until the 2-minute
                // Dataverse plugin timeout - the failure is the demo punchline and must be snappy.
                SecretClientOptions options = new SecretClientOptions();
                options.Retry.MaxRetries = 0;
                options.Retry.NetworkTimeout = TimeSpan.FromSeconds(10);

                SecretClient client = new SecretClient(
                    vaultUri,
                    new DataverseManagedIdentityTokenCredential(_managedIdentityService, _tracing),
                    options);

                _tracing.Trace("Calling Key Vault GetSecret for '{0}'.", secretName);
                KeyVaultSecret secret = client.GetSecret(secretName);
                _tracing.Trace("Secret '{0}' retrieved (length {1}).", secretName, secret.Value?.Length ?? 0);
                return secret.Value;
            }
            catch (InvalidPluginExecutionException)
            {
                throw;
            }
            catch (RequestFailedException requestEx)
            {
                throw new InvalidPluginExecutionException(
                    $"Key Vault call FAILED (HTTP {requestEx.Status}). " +
                    "403 = the vault firewall does not allow this environment's network (the vault is " +
                    "'outside' the VNet - expected in the Network/Demo 2 environment), or the Managed " +
                    "Identity is missing the 'Key Vault Secrets User' role; 404 = wrong secret name. " +
                    $"Details: {requestEx.Message}", requestEx);
            }
            catch (Exception ex)
            {
                // Transport-level failure (no route / timeout / socket) - e.g. the vault is firewalled
                // off from this environment's egress and never completes the TLS handshake.
                throw new InvalidPluginExecutionException(
                    "Key Vault call FAILED at the network layer: the vault could not be reached from " +
                    "this environment (firewall / no network path - the vault is 'outside'). This is the " +
                    $"expected result in the Network (Demo 2) environment. Inner: {ex.Message}", ex);
            }
        }

        private sealed class DataverseManagedIdentityTokenCredential : TokenCredential
        {
            private readonly IManagedIdentityService _managedIdentityService;
            private readonly ITracingService _tracing;

            public DataverseManagedIdentityTokenCredential(
                IManagedIdentityService managedIdentityService,
                ITracingService tracing)
            {
                _managedIdentityService = managedIdentityService;
                _tracing = tracing;
            }

            public override AccessToken GetToken(TokenRequestContext requestContext, System.Threading.CancellationToken cancellationToken)
            {
                _tracing.Trace("Acquiring access token from IManagedIdentityService for scope '{0}'.", KeyVaultScope);

                string token = _managedIdentityService.AcquireToken(new[] { KeyVaultScope });
                if (string.IsNullOrWhiteSpace(token))
                {
                    throw new InvalidPluginExecutionException(
                        $"IManagedIdentityService returned an empty token for scope '{KeyVaultScope}'.");
                }

                return new AccessToken(token, DateTimeOffset.UtcNow.AddMinutes(5));
            }

            public override System.Threading.Tasks.ValueTask<AccessToken> GetTokenAsync(
                TokenRequestContext requestContext,
                System.Threading.CancellationToken cancellationToken)
            {
                return new System.Threading.Tasks.ValueTask<AccessToken>(GetToken(requestContext, cancellationToken));
            }
        }
    }
}
