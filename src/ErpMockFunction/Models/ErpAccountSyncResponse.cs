using System.Text.Json.Serialization;

namespace ErpMockFunction.Models;

public sealed class ErpAccountSyncResponse
{
    [JsonPropertyName("erpNumber")]
    public string ErpNumber { get; init; } = string.Empty;
}
