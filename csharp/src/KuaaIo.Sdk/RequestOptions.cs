namespace KuaaIo.Sdk;

/// <summary>Options for one call.</summary>
public sealed record RequestOptions
{
    /// <summary>
    /// Makes a write safe to repeat: the same key with the same request
    /// answers the first response again; with another request, a 409. Reads
    /// ignore it.
    /// </summary>
    public string? IdempotencyKey { get; init; }

    /// <summary>Sends this call with another key.</summary>
    public string? ApiKey { get; init; }
}
