using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;

namespace KuaaIo.Sdk;

/// <summary>
/// A request the API refused. <see cref="Code"/> is the API's, the one to
/// branch on: unauthenticated, forbidden, not_found, conflict,
/// idempotency_key_reused, validation_failed, payment_required,
/// malformed_json, body_too_large, rate_limited… <see cref="Fields"/> says,
/// for validation_failed, what is wrong with each field.
/// <see cref="RetryAfter"/> is how many seconds the API asked to wait, on a
/// 429 or a 503.
/// </summary>
public sealed class KuaaException : Exception
{
    private static readonly IReadOnlyDictionary<string, IReadOnlyList<string>> NoFields = new Dictionary<string, IReadOnlyList<string>>();

    /// <summary>A refusal.</summary>
    /// <param name="status">The HTTP status.</param>
    /// <param name="code">The API's error code, empty when it sent none.</param>
    /// <param name="apiMessage">The API's message, empty when it sent none.</param>
    /// <param name="fields">What is wrong with each field.</param>
    /// <param name="retryAfter">Seconds to wait before trying again, or null.</param>
    /// <param name="requestId">The X-Request-ID header, or null.</param>
    public KuaaException(int status, string code, string apiMessage, IReadOnlyDictionary<string, IReadOnlyList<string>>? fields = null, int? retryAfter = null, string? requestId = null)
        : base(apiMessage.Length > 0 ? $"kuaa: {status} {code}: {apiMessage}" : $"kuaa: {status} {code}")
    {
        Status = status;
        Code = code;
        ApiMessage = apiMessage;
        Fields = fields ?? NoFields;
        RetryAfter = retryAfter;
        RequestId = requestId;
    }

    /// <summary>The HTTP status.</summary>
    public int Status { get; }

    /// <summary>The API's error code: validation_failed, not_found…</summary>
    public string Code { get; }

    /// <summary>The API's message, empty when it sent none.</summary>
    public string ApiMessage { get; }

    /// <summary>For validation_failed, what is wrong with each field.</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<string>> Fields { get; }

    /// <summary>On a 429 or a 503, how many seconds to wait; null otherwise.</summary>
    public int? RetryAfter { get; }

    /// <summary>The X-Request-ID header, or null.</summary>
    public string? RequestId { get; }

    /// <summary>The refusal a response carries; a body that is not the API's JSON is still a refusal.</summary>
    internal static KuaaException FromResponse(int status, string? retryAfter, string? requestId, byte[] body)
    {
        string code = "", message = "";
        var fields = new Dictionary<string, IReadOnlyList<string>>();
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("error", out var problem) && problem.ValueKind == JsonValueKind.Object)
            {
                code = Text(problem, "code");
                message = Text(problem, "message");
                if (problem.TryGetProperty("fields", out var problems) && problems.ValueKind == JsonValueKind.Object)
                {
                    foreach (var field in problems.EnumerateObject())
                    {
                        var list = new List<string>();
                        if (field.Value.ValueKind == JsonValueKind.Array)
                        {
                            foreach (var each in field.Value.EnumerateArray())
                            {
                                if (each.ValueKind == JsonValueKind.String)
                                {
                                    list.Add(each.GetString()!);
                                }
                            }
                        }
                        fields[field.Name] = list;
                    }
                }
            }
        }
        catch (JsonException)
        {
            // A refusal without a JSON body is still a refusal.
        }
        int? seconds = int.TryParse(retryAfter?.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
        return new KuaaException(status, code, message, fields, seconds, requestId);
    }

    private static string Text(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()! : "";
}
