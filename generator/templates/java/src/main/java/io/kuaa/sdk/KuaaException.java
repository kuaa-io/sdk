package io.kuaa;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A request the API refused. {@link #getCode()} is the API's, the one to
 * branch on: unauthenticated, forbidden, not_found, conflict,
 * idempotency_key_reused, validation_failed, payment_required,
 * malformed_json, body_too_large, rate_limited… {@link #getFields()} says,
 * for validation_failed, what is wrong with each field.
 * {@link #getRetryAfter()} is how many seconds the API asked to wait, on a
 * 429 or a 503.
 */
public class KuaaException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    /** The HTTP status. */
    private final int status;
    /** The API's error code. */
    private final String code;
    /** The API's message. */
    private final String apiMessage;
    /** What is wrong with each field. */
    private final Map<String, List<String>> fields;
    /** Seconds to wait before trying again, or null. */
    private final Integer retryAfter;
    /** The X-Request-ID header, or null. */
    private final String requestId;

    /**
     * A refusal.
     *
     * @param status the HTTP status
     * @param code the API's error code, empty when it sent none
     * @param apiMessage the API's message, empty when it sent none
     * @param fields what is wrong with each field
     * @param retryAfter seconds to wait before trying again, or null
     * @param requestId the X-Request-ID header, or null
     */
    public KuaaException(int status, String code, String apiMessage, Map<String, List<String>> fields, Integer retryAfter, String requestId) {
        super(apiMessage.isEmpty() ? "kuaa: " + status + " " + code : "kuaa: " + status + " " + code + ": " + apiMessage);
        this.status = status;
        this.code = code;
        this.apiMessage = apiMessage;
        this.fields = Collections.unmodifiableMap(new LinkedHashMap<>(fields));
        this.retryAfter = retryAfter;
        this.requestId = requestId;
    }

    /** @return the HTTP status */
    public int getStatus() {
        return status;
    }

    /** @return the API's error code: validation_failed, not_found… */
    public String getCode() {
        return code;
    }

    /** @return the API's message, empty when it sent none */
    public String getApiMessage() {
        return apiMessage;
    }

    /** @return for validation_failed, what is wrong with each field */
    public Map<String, List<String>> getFields() {
        return fields;
    }

    /** @return on a 429 or a 503, how many seconds to wait; null otherwise */
    public Integer getRetryAfter() {
        return retryAfter;
    }

    /** @return the X-Request-ID header, or null */
    public String getRequestId() {
        return requestId;
    }

    /** The refusal a response carries; a body that is not the API's JSON is still a refusal. */
    static KuaaException of(Transport.Response response) {
        Map<String, Object> problem = Collections.emptyMap();
        try {
            Object parsed = Json.parse(new String(response.getBody(), StandardCharsets.UTF_8));
            if (parsed instanceof Map && Json.asObject(parsed).get("error") instanceof Map) {
                problem = Json.asObject(Json.asObject(parsed).get("error"));
            }
        } catch (IllegalStateException e) {
            // A refusal without a JSON body is still a refusal.
        }
        Map<String, List<String>> fields = new LinkedHashMap<>();
        if (problem.get("fields") instanceof Map) {
            for (Map.Entry<String, Object> field : Json.asObject(problem.get("fields")).entrySet()) {
                List<String> problems = new ArrayList<>();
                if (field.getValue() instanceof List) {
                    for (Object each : (List<?>) field.getValue()) {
                        if (each instanceof String) {
                            problems.add((String) each);
                        }
                    }
                }
                fields.put(field.getKey(), Collections.unmodifiableList(problems));
            }
        }
        String retryAfter = response.getHeaders().getOrDefault("retry-after", "").trim();
        Integer seconds = null;
        if (!retryAfter.isEmpty() && retryAfter.length() < 10 && retryAfter.chars().allMatch(Character::isDigit)) {
            seconds = Integer.parseInt(retryAfter);
        }
        return new KuaaException(response.getStatus(), text(problem.get("code")), text(problem.get("message")), fields, seconds,
                response.getHeaders().get("x-request-id"));
    }

    private static String text(Object value) {
        return value instanceof String ? (String) value : "";
    }
}
