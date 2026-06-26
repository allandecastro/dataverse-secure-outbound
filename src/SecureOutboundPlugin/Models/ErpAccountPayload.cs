using System;
using Newtonsoft.Json;

namespace Dataverse.SecureOutbound.Models
{
    /// <summary>
    /// Payload sent to the ERP API for Account synchronization.
    /// </summary>
    public sealed class ErpAccountPayload
    {
        [JsonProperty("accountId")]
        public Guid AccountId { get; set; }

        [JsonProperty("name")]
        public string Name { get; set; }

        [JsonProperty("crmNumber")]
        public string CrmNumber { get; set; }
    }
}
