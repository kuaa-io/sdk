import type { WebhookEvent } from "./models.ts";

/** The headers KUAA signs every webhook delivery with. */
export const WEBHOOK_HEADER_DELIVERY_ID = "X-Arandu-Delivery-Id";
export const WEBHOOK_HEADER_TIMESTAMP = "X-Arandu-Timestamp";
export const WEBHOOK_HEADER_SIGNATURE = "X-Arandu-Signature";

/** How far from now, in seconds, a delivery's timestamp may be, either way. */
export const WEBHOOK_TOLERANCE_SECONDS = 300;

/** One signature per secret still signing: the current one and at most five previous ones. */
const MAX_SIGNATURES = 6;

/** A delivery KUAA did not sign with the secret, or signed too long ago. */
export class WebhookVerificationError extends Error {
  constructor(message = "kuaa: webhook signature does not verify") {
    super(message);
    this.name = "WebhookVerificationError";
  }
}

/** A request's headers, from fetch or from Node's http. */
export type HeadersLike = Headers | Record<string, string | string[] | undefined>;

/** Every value of a header, in any case; fetch's Headers joins repeated lines with commas. */
function values(headers: HeadersLike, name: string): string[] {
  if (typeof (headers as Headers).get === "function") {
    const value = (headers as Headers).get(name);
    return value === null ? [] : [value];
  }
  const out: string[] = [];
  for (const [key, value] of Object.entries(headers as Record<string, string | string[] | undefined>)) {
    if (key.toLowerCase() === name.toLowerCase() && value !== undefined) {
      out.push(...(Array.isArray(value) ? value : [value]));
    }
  }
  return out;
}

function hex(text: string): Uint8Array<ArrayBuffer> | undefined {
  if (!/^[0-9a-fA-F]{64}$/.test(text)) {
    return undefined;
  }
  const bytes = new Uint8Array(32);
  for (let i = 0; i < 32; i++) {
    bytes[i] = Number.parseInt(text.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

/**
 * Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0
 * envelope. The signature is
 * sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id + "." + body)),
 * keyed with the endpoint's secret exactly as it was shown; during a rotation
 * the X-Arandu-Signature header comes once per secret, and any one matching is
 * enough. A timestamp more than five minutes from now is refused. Pass the
 * body exactly as it arrived, before parsing it, and deduplicate on the
 * event's id: delivery is at least once.
 */
export async function verifyWebhook(secret: string, headers: HeadersLike, body: string | Uint8Array, now: number = Date.now()): Promise<WebhookEvent> {
  if (!secret) {
    throw new Error("kuaa: the webhook secret is empty");
  }
  const delivery = (values(headers, WEBHOOK_HEADER_DELIVERY_ID)[0] ?? "").trim();
  const stamp = (values(headers, WEBHOOK_HEADER_TIMESTAMP)[0] ?? "").trim();
  if (!delivery || !/^\d+$/.test(stamp) || Math.abs(Math.floor(now / 1000) - Number(stamp)) > WEBHOOK_TOLERANCE_SECONDS) {
    throw new WebhookVerificationError();
  }
  const signature = values(headers, WEBHOOK_HEADER_SIGNATURE).join(",");
  const entries = signature.split(",");
  if (!signature.trim() || entries.length > MAX_SIGNATURES) {
    throw new WebhookVerificationError();
  }
  const given: Uint8Array<ArrayBuffer>[] = [];
  for (const entry of entries) {
    const trimmed = entry.trim();
    const decoded = trimmed.startsWith("sha256=") ? hex(trimmed.slice("sha256=".length)) : undefined;
    if (!decoded) {
      throw new WebhookVerificationError();
    }
    given.push(decoded);
  }
  const encoder = new TextEncoder();
  const raw = typeof body === "string" ? encoder.encode(body) : body;
  const prefix = encoder.encode(`${stamp}.${delivery}.`);
  const signed = new Uint8Array(prefix.length + raw.length);
  signed.set(prefix);
  signed.set(raw, prefix.length);
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  let matched = false;
  for (const each of given) {
    // subtle.verify compares in constant time.
    if (await crypto.subtle.verify("HMAC", key, each, signed)) {
      matched = true;
    }
  }
  if (!matched) {
    throw new WebhookVerificationError();
  }
  return JSON.parse(new TextDecoder().decode(raw)) as WebhookEvent;
}
