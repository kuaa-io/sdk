package io.kuaa;

/** A delivery KUAA did not sign with the secret, or signed too long ago. */
public final class WebhookVerificationException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    /** The refusal. */
    public WebhookVerificationException() {
        super("kuaa: webhook signature does not verify");
    }
}
