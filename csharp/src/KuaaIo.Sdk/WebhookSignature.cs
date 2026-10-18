using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace KuaaIo.Sdk;

/// <summary>Verifying the webhooks KUAA sends.</summary>
public static class WebhookSignature
{
    /// <summary>The header with the delivery id, the same on every retry.</summary>
    public const string HeaderDeliveryId = "X-Arandu-Delivery-Id";

    /// <summary>The header with the Unix time, in seconds, the attempt was signed at.</summary>
    public const string HeaderTimestamp = "X-Arandu-Timestamp";

    /// <summary>The header with the signatures, one line per secret still signing.</summary>
    public const string HeaderSignature = "X-Arandu-Signature";

    /// <summary>How far from now a delivery's timestamp may be, either way.</summary>
    public static readonly TimeSpan Tolerance = TimeSpan.FromMinutes(5);

    // One signature per secret still signing: the current one and at most five previous ones.
    private const int MaxSignatures = 6;

    /// <summary>
    /// Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0
    /// envelope. The signature is
    /// <c>sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id + "." + body))</c>,
    /// keyed with the endpoint's secret exactly as it was shown; during a
    /// rotation the X-Arandu-Signature header comes once per secret, and any
    /// one matching is enough. A timestamp more than five minutes from now is
    /// refused. Pass the body exactly as it arrived, before parsing it, and
    /// deduplicate on the event's id: delivery is at least once.
    /// </summary>
    /// <typeparam name="TValue">A header's value: a string, or several of them (ASP.NET's StringValues, HttpHeaders' lists).</typeparam>
    /// <param name="secret">The endpoint's secret.</param>
    /// <param name="headers">The request's headers, by any case.</param>
    /// <param name="body">The raw body.</param>
    /// <param name="now">The moment the timestamp is checked against; the current time when null.</param>
    /// <returns>The event.</returns>
    /// <exception cref="WebhookVerificationException">KUAA did not sign the delivery with the secret, or signed it too long ago.</exception>
    public static WebhookEvent Verify<TValue>(string secret, IEnumerable<KeyValuePair<string, TValue>> headers, byte[] body, DateTimeOffset? now = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(secret);
        ArgumentNullException.ThrowIfNull(headers);
        ArgumentNullException.ThrowIfNull(body);
        var delivery = First(Values(headers, HeaderDeliveryId));
        var stamp = First(Values(headers, HeaderTimestamp));
        if (delivery.Length == 0 || stamp.Length is 0 or > 18 || !Digits(stamp))
        {
            throw new WebhookVerificationException();
        }
        var at = (now ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds();
        if (Math.Abs(at - long.Parse(stamp, NumberStyles.None, CultureInfo.InvariantCulture)) > (long)Tolerance.TotalSeconds)
        {
            throw new WebhookVerificationException();
        }
        var signature = string.Join(',', Values(headers, HeaderSignature));
        var entries = signature.Split(',');
        if (signature.Trim().Length == 0 || entries.Length > MaxSignatures)
        {
            throw new WebhookVerificationException();
        }
        var given = new List<byte[]>();
        foreach (var entry in entries)
        {
            var trimmed = entry.Trim();
            if (!trimmed.StartsWith("sha256=", StringComparison.Ordinal) || trimmed.Length != 7 + 64 || !Hex(trimmed.AsSpan(7)))
            {
                throw new WebhookVerificationException();
            }
            given.Add(Convert.FromHexString(trimmed.AsSpan(7)));
        }
        var prefix = Encoding.UTF8.GetBytes(stamp + "." + delivery + ".");
        var signed = new byte[prefix.Length + body.Length];
        prefix.CopyTo(signed, 0);
        body.CopyTo(signed, prefix.Length);
        var expected = HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), signed);
        var matched = false;
        foreach (var each in given)
        {
            matched |= CryptographicOperations.FixedTimeEquals(each, expected);
        }
        if (!matched)
        {
            throw new WebhookVerificationException();
        }
        return JsonSerializer.Deserialize(body, KuaaJson.Default.WebhookEvent)
            ?? throw new JsonException("kuaa: the webhook has no body");
    }

    /// <summary>
    /// <see cref="Verify{TValue}(string, IEnumerable{KeyValuePair{string, TValue}}, byte[], DateTimeOffset?)"/>
    /// with the body as text, encoded in UTF-8.
    /// </summary>
    /// <typeparam name="TValue">A header's value: a string, or several of them.</typeparam>
    /// <param name="secret">The endpoint's secret.</param>
    /// <param name="headers">The request's headers, by any case.</param>
    /// <param name="body">The raw body.</param>
    /// <param name="now">The moment the timestamp is checked against; the current time when null.</param>
    /// <returns>The event.</returns>
    /// <exception cref="WebhookVerificationException">KUAA did not sign the delivery with the secret, or signed it too long ago.</exception>
    public static WebhookEvent Verify<TValue>(string secret, IEnumerable<KeyValuePair<string, TValue>> headers, string body, DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(body);
        return Verify(secret, headers, Encoding.UTF8.GetBytes(body), now);
    }

    private static bool Digits(string text)
    {
        foreach (var c in text)
        {
            if (!char.IsAsciiDigit(c))
            {
                return false;
            }
        }
        return true;
    }

    private static bool Hex(ReadOnlySpan<char> text)
    {
        foreach (var c in text)
        {
            if (!char.IsAsciiHexDigit(c))
            {
                return false;
            }
        }
        return true;
    }

    private static string First(List<string> values) => values.Count == 0 ? "" : values[0].Trim();

    private static List<string> Values<TValue>(IEnumerable<KeyValuePair<string, TValue>> headers, string name)
    {
        var out_ = new List<string>();
        foreach (var header in headers)
        {
            if (!string.Equals(header.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            switch (header.Value)
            {
                case null:
                    break;
                case string text:
                    out_.Add(text);
                    break;
                case IEnumerable<string> values:
                    foreach (var value in values)
                    {
                        if (value is not null)
                        {
                            out_.Add(value);
                        }
                    }
                    break;
                default:
                    out_.Add(header.Value.ToString() ?? "");
                    break;
            }
        }
        return out_;
    }
}
