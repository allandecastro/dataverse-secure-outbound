# ERP Mock Function

Simple Azure Function (HTTP trigger) used for demo 2.

- **Route:** `POST /api/erp/account-sync`
- **Request body:**

```json
{
  "accountId": "4878571d-afd3-eef2-80fd-c4dd78ac3b4a",
  "crmNumber": "CRM-10042",
  "name": "Contoso Ltd"
}
```

- **Response body:**

```json
{
  "erpNumber": "ERP20260610-1A2B3C4D"
}
```

## Local run

1. Copy `local.settings.json.example` to `local.settings.json`.
2. Run with Azure Functions Core Tools:
   `func start`
