using System;
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace Dataverse.SecureOutbound.Services
{
    /// <summary>
    /// Resolves Dataverse Environment Variable values. Dataverse stores the definition
    /// (<c>environmentvariabledefinition</c>) separately from any overridden value
    /// (<c>environmentvariablevalue</c>); this service prefers the current value and falls back
    /// to the definition's default — mirroring how Dataverse itself resolves them.
    ///
    /// Reads values directly from Dataverse on each call so changes are effective immediately
    /// without requiring cache invalidation or worker recycle.
    /// </summary>
    public sealed class EnvironmentVariableService : IEnvironmentVariableValueProvider
    {
        private readonly IOrganizationService _service;
        private readonly ITracingService _tracing;

        public EnvironmentVariableService(IOrganizationService service, ITracingService tracing)
        {
            _service = service ?? throw new ArgumentNullException(nameof(service));
            _tracing = tracing ?? throw new ArgumentNullException(nameof(tracing));
        }

        /// <summary>
        /// Resolves the effective value of a single Environment Variable by schema name,
        /// querying Dataverse directly each time.
        /// </summary>
        /// <param name="schemaName">The schema name of the Environment Variable to resolve.</param>
        /// <returns>The resolved value, or <c>null</c> if the variable does not exist or has no value.</returns>
        public string GetValue(string schemaName)
        {
            _tracing.Trace("Resolving Environment Variable '{0}' from Dataverse.", schemaName);
            return QueryDataverse(schemaName);
        }

        private string QueryDataverse(string schemaName)
        {
            QueryExpression query = new QueryExpression("environmentvariabledefinition")
            {
                ColumnSet = new ColumnSet("defaultvalue", "schemaname"),
                Criteria =
                {
                    Conditions =
                    {
                        new ConditionExpression("schemaname", ConditionOperator.Equal, schemaName)
                    }
                }
            };

            var valueLink = new LinkEntity(
                "environmentvariabledefinition",
                "environmentvariablevalue",
                "environmentvariabledefinitionid",
                "environmentvariabledefinitionid",
                JoinOperator.LeftOuter)
            {
                Columns = new ColumnSet("value"),
                EntityAlias = "v"
            };
            query.LinkEntities.Add(valueLink);

            EntityCollection results = _service.RetrieveMultiple(query);
            if (results.Entities.Count == 0)
            {
                _tracing.Trace("Environment Variable definition '{0}' does not exist.", schemaName);
                return null;
            }

            Entity record = results.Entities[0];

            string currentValue = null;
            if (record.Contains("v.value") && record["v.value"] is AliasedValue aliased)
            {
                currentValue = aliased.Value as string;
            }

            if (!string.IsNullOrWhiteSpace(currentValue))
            {
                _tracing.Trace("Using current value for '{0}'.", schemaName);
                return currentValue;
            }

            string defaultValue = record.GetAttributeValue<string>("defaultvalue");
            _tracing.Trace("No current value for '{0}'; falling back to default value.", schemaName);
            return defaultValue;
        }
    }
}
