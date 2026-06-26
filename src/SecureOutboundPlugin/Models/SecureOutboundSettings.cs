namespace Dataverse.SecureOutbound.Models
{
    /// <summary>
    /// Immutable holder for the validated configuration resolved from Dataverse
    /// Environment Variables: Key Vault coordinates and ERP endpoint.
    /// </summary>
    public sealed class SecureOutboundSettings
    {
        public SecureOutboundSettings(
            string keyVaultUrl,
            string secretName,
            string erpApiUrl)
        {
            KeyVaultUrl      = keyVaultUrl;
            SecretName       = secretName;
            ErpApiUrl        = erpApiUrl;
        }

        /// <summary>The Azure Key Vault base URL.</summary>
        public string KeyVaultUrl { get; }

        /// <summary>The name of the secret to retrieve from Key Vault (Identity pillar).</summary>
        public string SecretName { get; }

        /// <summary>The Function App / ERP endpoint to POST Account data to (Network pillar).</summary>
        public string ErpApiUrl { get; }
    }
}
