using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading.Tasks;
using Dataverse.SecureOutbound.Models;
using Microsoft.Xrm.Sdk;
using Newtonsoft.Json;

namespace Dataverse.SecureOutbound.Services
{
    /// <summary>
    /// Sends Account data to the ERP / Function App over HTTPS. The bearer token is a simple demo
    /// token — this path is intentionally decoupled from Key Vault: the boundary being demonstrated
    /// here is the network (private endpoint / VNet), not the secret store.
    /// </summary>
    public sealed class ErpService : IErpService
    {
        private static readonly HttpClient _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(30)
        };

        private readonly ITracingService _tracing;

        public ErpService(ITracingService tracing)
        {
            _tracing = tracing ?? throw new ArgumentNullException(nameof(tracing));
        }

        /// <summary>
        /// POSTs the Account payload to the ERP and returns the ERP-assigned number.
        /// </summary>
        public string SyncAccount(string erpApiUrl, string bearerToken, Entity account)
        {
            _tracing.Trace("ErpService: building payload for Account '{0}'.", account.Id);

            string payload = BuildPayload(account);
            _tracing.Trace("ErpService: POST to '{0}'.", erpApiUrl);

            using (var request = new HttpRequestMessage(HttpMethod.Post, erpApiUrl))
            {
                request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
                request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

                HttpResponseMessage response;
                try
                {
                    response = _httpClient.SendAsync(request).GetAwaiter().GetResult();
                }
                catch (HttpRequestException httpEx)
                {
                    throw new InvalidPluginExecutionException(
                        "Function App call FAILED: the private Function endpoint is not reachable from " +
                        "this environment's egress (no VNet / subnet injection). This is the expected " +
                        $"result in the Identity (Demo 1) environment. Inner: {httpEx.Message}", httpEx);
                }
                catch (TaskCanceledException timeoutEx)
                {
                    throw new InvalidPluginExecutionException(
                        "Function App call TIMED OUT: the private Function endpoint did not respond " +
                        "(no network path from this environment). This is the expected result in the " +
                        $"Identity (Demo 1) environment. Inner: {timeoutEx.Message}", timeoutEx);
                }

                using (response)
                {
                    string body = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                    _tracing.Trace("ErpService: response HTTP {0}.", (int)response.StatusCode);
                    _tracing.Trace("ErpService: response body preview: {0}", Truncate(body, 500));

                    if (!response.IsSuccessStatusCode)
                    {
                        throw new InvalidPluginExecutionException(
                            $"ERP returned HTTP {(int)response.StatusCode}. Body: {Truncate(body, 500)}");
                    }

                    string erpNumber = ParseErpNumber(body);
                    if (string.IsNullOrWhiteSpace(erpNumber))
                    {
                        throw new InvalidPluginExecutionException(
                            $"ERP returned HTTP {(int)response.StatusCode} but no erpNumber. Body: {Truncate(body, 500)}");
                    }

                    _tracing.Trace("ErpService: ERP number received (length {0}).", erpNumber?.Length ?? 0);
                    return erpNumber;
                }
            }
        }

        private static string BuildPayload(Entity account)
        {
            ErpAccountPayload payload = new ErpAccountPayload
            {
                AccountId = account.Id,
                Name = account.GetAttributeValue<string>("name"),
                CrmNumber = account.GetAttributeValue<string>("accountnumber")
            };

            return JsonConvert.SerializeObject(payload, Formatting.None);
        }

        private static string ParseErpNumber(string body)
        {
            if (string.IsNullOrWhiteSpace(body))
            {
                return null;
            }

            try
            {
                ErpAccountResponse response = JsonConvert.DeserializeObject<ErpAccountResponse>(body);
                return response?.ErpNumber;
            }
            catch (JsonException)
            {
                return Truncate(body.Trim(), 100);
            }
        }

        private static string Truncate(string value, int max) =>
            value != null && value.Length > max ? value.Substring(0, max) + "…" : value;
    }
}
