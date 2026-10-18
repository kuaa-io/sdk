/** Options for one call. */
export interface RequestOptions {
  /**
   * Makes a write safe to repeat: the same key with the same request answers
   * the first response again; with another request, a 409.
   */
  idempotencyKey?: string;
  /** Sends this call with another organization's key. */
  apiKey?: string;
  /** Cancels the call. */
  signal?: AbortSignal;
}

/** One file of a multipart body. */
export interface KuaaFile {
  /** The name the part carries, such as frente.jpg. */
  filename: string;
  /** The file's media type: image/jpeg or image/png. */
  contentType?: string;
  data: Uint8Array | Blob;
}

/** A query string's values; undefined ones are left out, a list repeats its name. */
export type Query = Record<string, string | number | boolean | string[] | undefined>;

export interface RequestSpec {
  query?: Query | undefined;
  body?: unknown;
  /** Sends body as multipart/form-data instead of JSON. */
  multipart?: boolean;
  options?: RequestOptions | undefined;
}

/** What the API said about an answer, beside its body. */
export interface ResponseInfo {
  status: number;
  /** The Kuaa-Livemode header: true for live, false for a sandbox, null when absent. */
  livemode: boolean | null;
  /** The Kuaa-Environment header: live or sandbox. */
  environment: string | null;
  /** The answer is the stored answer of an earlier request with the same Idempotency-Key. */
  idempotentReplayed: boolean;
  /** The X-Request-ID header. */
  requestId: string | null;
}

/** The API's envelope: data, and a list's cursor. */
export interface Envelope {
  data: Record<string, unknown>;
  meta?: { next_cursor?: string | null; has_more?: boolean };
}

/** What a service calls the API through. */
export interface Requester {
  request(method: string, path: string, spec?: RequestSpec): Promise<Envelope>;
}
