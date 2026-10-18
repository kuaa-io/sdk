namespace KuaaIo.Sdk;

/// <summary>What the API said about an answer, beside its body.</summary>
/// <param name="Status">The HTTP status.</param>
/// <param name="Livemode">The Kuaa-Livemode header: true for live, false for a sandbox, null when absent.</param>
/// <param name="Environment">The Kuaa-Environment header: live or sandbox.</param>
/// <param name="IdempotentReplayed">The answer is the stored answer of an earlier request with the same Idempotency-Key.</param>
/// <param name="RequestId">The X-Request-ID header.</param>
public sealed record ResponseInfo(int Status, bool? Livemode, string? Environment, bool IdempotentReplayed, string? RequestId);
