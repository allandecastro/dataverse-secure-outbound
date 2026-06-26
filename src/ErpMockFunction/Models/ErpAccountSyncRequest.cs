using System.Text.Json.Serialization;

namespace ErpMockFunction.Models;

public sealed class ErpAccountSyncRequest
{
    [JsonPropertyName("accountId")]
    public string? AccountId { get; set; }

    [JsonPropertyName("crmNumber")]
    public string? CrmNumber { get; set; }

    [JsonPropertyName("name")]
    public string? Name { get; set; }
}
