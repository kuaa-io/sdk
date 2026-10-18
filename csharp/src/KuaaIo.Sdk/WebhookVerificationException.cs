using System;

namespace KuaaIo.Sdk;

/// <summary>A delivery KUAA did not sign with the secret, or signed too long ago.</summary>
public sealed class WebhookVerificationException : Exception
{
    /// <summary>The refusal of a delivery.</summary>
    public WebhookVerificationException()
        : base("kuaa: webhook signature does not verify")
    {
    }
}
