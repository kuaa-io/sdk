/**
 * A request the API refused. `code` is the API's, the one to branch on:
 * unauthenticated, forbidden, not_found, conflict, idempotency_key_reused,
 * validation_failed, payment_required, malformed_json, body_too_large,
 * rate_limited… `fields` says, for validation_failed, what is wrong with each
 * field. `retryAfter` is how many seconds the API asked to wait, on a 429 or
 * a 503.
 */
export class KuaaError extends Error {
  readonly status: number;
  readonly code: string;
  readonly fields: Record<string, string[]>;
  readonly retryAfter: number | undefined;
  readonly requestId: string | undefined;

  constructor(status: number, code: string, message: string, fields: Record<string, string[]> = {}, retryAfter?: number, requestId?: string) {
    super(message ? `kuaa: ${status} ${code}: ${message}` : `kuaa: ${status} ${code}`);
    this.name = "KuaaError";
    this.status = status;
    this.code = code;
    this.fields = fields;
    this.retryAfter = retryAfter;
    this.requestId = requestId;
  }

  /** The error a refused response carries. */
  static async from(response: Response): Promise<KuaaError> {
    let body: { error?: { code?: string; message?: string; fields?: Record<string, string[]> } } = {};
    try {
      body = (await response.json()) as typeof body;
    } catch {
      // A refusal without a JSON body is still a refusal.
    }
    const problem = body?.error ?? {};
    const seconds = /^\s*\d+\s*$/.test(response.headers.get("retry-after") ?? "") ? Number(response.headers.get("retry-after")) : undefined;
    return new KuaaError(response.status, problem.code ?? "", problem.message ?? "", problem.fields ?? {}, seconds, response.headers.get("x-request-id") ?? undefined);
  }
}
