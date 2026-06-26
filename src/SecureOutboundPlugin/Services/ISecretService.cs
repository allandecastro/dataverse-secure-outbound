namespace Dataverse.SecureOutbound.Services
{
    /// <summary>
    /// Abstraction over the secure outbound secret store. Today the only implementation is
    /// <see cref="KeyVaultSecretService"/> (Azure Key Vault over Managed Identity), but the
    /// interface keeps the plug-in decoupled from the concrete store — handy for swapping the
    /// target (another vault, a config service) or unit-testing the orchestration.
    /// </summary>
    public interface ISecretService
    {
        /// <summary>Retrieves the value of a named secret from the given vault URL.</summary>
        /// <param name="vaultUrl">The vault base URL.</param>
        /// <param name="secretName">The name of the secret to retrieve.</param>
        /// <returns>The secret value.</returns>
        string GetSecret(string vaultUrl, string secretName);
    }
}
