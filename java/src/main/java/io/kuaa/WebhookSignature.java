package io.kuaa;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Verifying the webhooks KUAA sends.
 *
 * <pre>{@code
 * WebhookEvent event = WebhookSignature.verify(System.getenv("KUAA_WEBHOOK_SECRET"), headers, rawBody);
 * }</pre>
 */
public final class WebhookSignature {
    /** The header with the delivery id, the same on every retry. */
    public static final String HEADER_DELIVERY_ID = "X-Arandu-Delivery-Id";
    /** The header with the Unix time, in seconds, the attempt was signed at. */
    public static final String HEADER_TIMESTAMP = "X-Arandu-Timestamp";
    /** The header with the signatures, one line per secret still signing. */
    public static final String HEADER_SIGNATURE = "X-Arandu-Signature";
    /** How far from now, in seconds, a delivery's timestamp may be, either way. */
    public static final long TOLERANCE_SECONDS = 300;

    /** One signature per secret still signing: the current one and at most five previous ones. */
    private static final int MAX_SIGNATURES = 6;

    private WebhookSignature() {
    }

    /**
     * Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0
     * envelope. The signature is
     * sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id + "." + body)),
     * keyed with the endpoint's secret exactly as it was shown; during a
     * rotation the X-Arandu-Signature header comes once per secret, and any
     * one matching is enough. A timestamp more than five minutes from now is
     * refused. Pass the body exactly as it arrived, before parsing it, and
     * deduplicate on the event's id: delivery is at least once.
     *
     * @param secret the endpoint's secret
     * @param headers the request's headers, names in any case, each with its lines
     * @param body the raw body
     * @return the event
     * @throws WebhookVerificationException when KUAA did not sign the delivery with the secret, or signed it too long ago
     */
    public static WebhookEvent verify(String secret, Map<String, ? extends Collection<String>> headers, byte[] body) {
        return verify(secret, headers, body, System.currentTimeMillis() / 1000);
    }

    /**
     * {@link #verify(String, Map, byte[])} against another clock.
     *
     * @param secret the endpoint's secret
     * @param headers the request's headers, names in any case, each with its lines
     * @param body the raw body
     * @param now the Unix time, in seconds, to check the timestamp against
     * @return the event
     * @throws WebhookVerificationException when KUAA did not sign the delivery with the secret, or signed it too long ago
     */
    public static WebhookEvent verify(String secret, Map<String, ? extends Collection<String>> headers, byte[] body, long now) {
        if (secret == null || secret.isEmpty()) {
            throw new IllegalArgumentException("kuaa: the webhook secret is empty");
        }
        String delivery = first(values(headers, HEADER_DELIVERY_ID));
        String stamp = first(values(headers, HEADER_TIMESTAMP));
        if (delivery.isEmpty() || stamp.isEmpty() || stamp.length() > 18 || !stamp.chars().allMatch(c -> c >= '0' && c <= '9')) {
            throw new WebhookVerificationException();
        }
        if (Math.abs(now - Long.parseLong(stamp)) > TOLERANCE_SECONDS) {
            throw new WebhookVerificationException();
        }
        String signature = String.join(",", values(headers, HEADER_SIGNATURE));
        String[] entries = signature.split(",", -1);
        if (signature.trim().isEmpty() || entries.length > MAX_SIGNATURES) {
            throw new WebhookVerificationException();
        }
        List<byte[]> given = new ArrayList<>();
        for (String entry : entries) {
            String trimmed = entry.trim();
            if (!trimmed.startsWith("sha256=") || !trimmed.substring(7).matches("[0-9a-fA-F]{64}")) {
                throw new WebhookVerificationException();
            }
            given.add(hex(trimmed.substring(7)));
        }
        byte[] expected;
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            mac.update((stamp + "." + delivery + ".").getBytes(StandardCharsets.UTF_8));
            expected = mac.doFinal(body);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("kuaa: HMAC-SHA256 is not available", e);
        }
        boolean matched = false;
        for (byte[] each : given) {
            matched |= MessageDigest.isEqual(each, expected);
        }
        if (!matched) {
            throw new WebhookVerificationException();
        }
        return WebhookEvent.fromJson(Json.asObject(Json.parse(new String(body, StandardCharsets.UTF_8))));
    }

    private static List<String> values(Map<String, ? extends Collection<String>> headers, String name) {
        List<String> out = new ArrayList<>();
        String wanted = name.toLowerCase(Locale.ROOT);
        for (Map.Entry<String, ? extends Collection<String>> header : headers.entrySet()) {
            if (header.getKey() != null && header.getKey().toLowerCase(Locale.ROOT).equals(wanted) && header.getValue() != null) {
                out.addAll(header.getValue());
            }
        }
        return out;
    }

    private static String first(List<String> values) {
        return values.isEmpty() || values.get(0) == null ? "" : values.get(0).trim();
    }

    private static byte[] hex(String text) {
        byte[] out = new byte[text.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(text.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }
}
