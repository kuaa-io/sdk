package io.kuaa;

import java.util.Map;

/** What the API said about an answer, beside its body. */
public final class ResponseInfo {
    private final int status;
    private final Boolean livemode;
    private final String environment;
    private final boolean idempotentReplayed;
    private final String requestId;

    ResponseInfo(int status, Map<String, String> headers) {
        this.status = status;
        String mode = headers.get("kuaa-livemode");
        this.livemode = "true".equals(mode) ? Boolean.TRUE : "false".equals(mode) ? Boolean.FALSE : null;
        this.environment = headers.get("kuaa-environment");
        this.idempotentReplayed = "true".equals(headers.get("idempotent-replayed"));
        this.requestId = headers.get("x-request-id");
    }

    /** @return the HTTP status */
    public int getStatus() {
        return status;
    }

    /** @return the Kuaa-Livemode header: true for live, false for a sandbox, null when absent */
    public Boolean getLivemode() {
        return livemode;
    }

    /** @return the Kuaa-Environment header, live or sandbox, or null */
    public String getEnvironment() {
        return environment;
    }

    /** @return whether the answer is the stored answer of an earlier request with the same Idempotency-Key */
    public boolean isIdempotentReplayed() {
        return idempotentReplayed;
    }

    /** @return the X-Request-ID header, or null */
    public String getRequestId() {
        return requestId;
    }

    @Override
    public String toString() {
        return "ResponseInfo{status=" + status + ", livemode=" + livemode + ", environment=" + environment
                + ", idempotentReplayed=" + idempotentReplayed + ", requestId=" + requestId + "}";
    }
}
