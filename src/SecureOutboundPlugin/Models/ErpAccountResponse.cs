using Newtonsoft.Json;

namespace Dataverse.SecureOutbound.Models
{
    /// <summary>
    /// Response from the ERP API after Account synchronization.
    /// </summary>
    public sealed class ErpAccountResponse
    {
        [JsonProperty("erpNumber")]
        public string ErpNumber { get; set; }
    }
}
