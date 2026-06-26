using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ErpMockFunction.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace ErpMockFunction.Functions;

public sealed class AccountSyncFunction
{
    private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
    {
        PropertyNameCaseInsensitive = true
    };

    [Function("AccountSync")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "erp/account-sync")] HttpRequestData request,
        FunctionContext executionContext)
    {
        ILogger logger = executionContext.GetLogger("AccountSync");
        if (!HasBearerToken(request))
        {
            HttpResponseData unauthorized = request.CreateResponse(HttpStatusCode.Unauthorized);
            await unauthorized.WriteAsJsonAsync(new { error = "Bearer token is required." });
            return unauthorized;
        }

        ErpAccountSyncRequest? payload = await JsonSerializer.DeserializeAsync<ErpAccountSyncRequest>(request.Body, JsonOptions);

        if (!TryValidate(payload, out string validationError))
        {
            HttpResponseData badRequest = request.CreateResponse(HttpStatusCode.BadRequest);
            await badRequest.WriteAsJsonAsync(new { error = validationError });
            return badRequest;
        }

        string erpNumber = GenerateErpNumber(payload!);
        logger.LogInformation("Generated ERP number for accountId '{AccountId}'.", payload!.AccountId);

        HttpResponseData ok = request.CreateResponse(HttpStatusCode.OK);
        ok.Headers.Add("Content-Type", "application/json; charset=utf-8");
        string json = JsonSerializer.Serialize(new ErpAccountSyncResponse { ErpNumber = erpNumber });
        await ok.WriteStringAsync(json);
        return ok;
    }

    private static bool TryValidate(ErpAccountSyncRequest? payload, out string error)
    {
        if (payload == null)
        {
            error = "Request body is required.";
            return false;
        }

        if (string.IsNullOrWhiteSpace(payload.AccountId) || !Guid.TryParse(payload.AccountId, out _))
        {
            error = "Field 'accountId' must be a valid GUID.";
            return false;
        }

        if (string.IsNullOrWhiteSpace(payload.CrmNumber))
        {
            error = "Field 'crmNumber' is required.";
            return false;
        }

        if (string.IsNullOrWhiteSpace(payload.Name))
        {
            error = "Field 'name' is required.";
            return false;
        }

        error = string.Empty;
        return true;
    }

    private static string GenerateErpNumber(ErpAccountSyncRequest payload)
    {
        string basis = $"{payload.AccountId}|{payload.CrmNumber}|{payload.Name}".ToUpperInvariant();
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(basis));
        string suffix = Convert.ToHexString(hash)[..8];
        return $"ERP{DateTime.UtcNow:yyyyMMdd}-{suffix}";
    }

    private static bool HasBearerToken(HttpRequestData request)
    {
        if (!request.Headers.TryGetValues("Authorization", out var values))
        {
            return false;
        }

        string? auth = values.FirstOrDefault();
        return !string.IsNullOrWhiteSpace(auth) &&
               auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) &&
               auth.Length > "Bearer ".Length;
    }
}
