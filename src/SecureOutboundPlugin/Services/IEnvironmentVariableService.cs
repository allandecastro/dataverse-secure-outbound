namespace Dataverse.SecureOutbound.Services
{
    /// <summary>
    /// Abstraction for reading Dataverse Environment Variables by schema name.
    /// </summary>
    public interface IEnvironmentVariableValueProvider
    {
        /// <summary>
        /// Resolves the effective value for an environment variable schema name.
        /// </summary>
        /// <param name="schemaName">Schema name of the environment variable definition.</param>
        /// <returns>The current value, default value, or <c>null</c> when unavailable.</returns>
        string GetValue(string schemaName);
    }
}
