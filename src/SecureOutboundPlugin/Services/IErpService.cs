using Microsoft.Xrm.Sdk;

namespace Dataverse.SecureOutbound.Services
{
    /// <summary>
    /// Abstraction over the outbound call to the Function App / ERP endpoint. Decoupled from Key Vault:
    /// the bearer token is a simple demo token, because the boundary demonstrated here is the network
    /// (private endpoint / VNet), not the secret store.
    /// </summary>
    public interface IErpService
    {
        /// <summary>
        /// Sends Account data to the Function App / ERP and returns the assigned number for the record.
        /// </summary>
        /// <param name="erpApiUrl">Base URL of the Function App / ERP endpoint.</param>
        /// <param name="bearerToken">Bearer token (a demo token; not sourced from Key Vault).</param>
        /// <param name="account">The Account entity with all fields to send.</param>
        /// <returns>The number assigned by the Function App / ERP system.</returns>
        string SyncAccount(string erpApiUrl, string bearerToken, Entity account);
    }
}
