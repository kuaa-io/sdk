use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

use crate::models::WebhookEvent;

/// The header with the delivery id, the same on every retry.
pub const WEBHOOK_HEADER_DELIVERY_ID: &str = "X-Arandu-Delivery-Id";
/// The header with the Unix time, in seconds, the attempt was signed at.
pub const WEBHOOK_HEADER_TIMESTAMP: &str = "X-Arandu-Timestamp";
/// The header with the signatures, one line per secret still signing.
pub const WEBHOOK_HEADER_SIGNATURE: &str = "X-Arandu-Signature";

/// How far from now a delivery's timestamp may be, either way.
pub const WEBHOOK_TOLERANCE: Duration = Duration::from_secs(300);

/// One signature per secret still signing: the current one and at most five
/// previous ones.
const MAX_SIGNATURES: usize = 6;

/// Why a delivery was not accepted.
#[derive(Debug)]
#[non_exhaustive]
pub enum WebhookError {
    /// The secret is empty.
    InvalidSecret,
    /// KUAA did not sign the delivery with the secret, or signed it too long
    /// ago.
    InvalidSignature,
    /// The body is signed but is not an event.
    InvalidPayload(serde_json::Error),
}

impl fmt::Display for WebhookError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WebhookError::InvalidSecret => f.write_str("kuaa: the webhook secret is empty"),
            WebhookError::InvalidSignature => {
                f.write_str("kuaa: webhook signature does not verify")
            }
            WebhookError::InvalidPayload(error) => write!(f, "kuaa: webhook payload: {error}"),
        }
    }
}

impl std::error::Error for WebhookError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            WebhookError::InvalidPayload(error) => Some(error),
            _ => None,
        }
    }
}

/// Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0
/// envelope. The signature is
/// `sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id + "." + body))`,
/// keyed with the endpoint's secret exactly as it was shown; during a
/// rotation the X-Arandu-Signature header comes once per secret, and any one
/// matching is enough. A timestamp more than five minutes from now is
/// refused. Pass the body exactly as it arrived, before parsing it, and
/// deduplicate on the event's id: delivery is at least once.
///
/// `headers` are the request's, their names in any case, a repeated header
/// once per line: a list of pairs, a `HashMap` or an `http::HeaderMap` by
/// reference.
pub fn verify_webhook<I, K, V>(
    secret: &str,
    headers: I,
    body: &[u8],
) -> Result<WebhookEvent, WebhookError>
where
    I: IntoIterator<Item = (K, V)>,
    K: AsRef<str>,
    V: AsRef<[u8]>,
{
    verify_webhook_at(secret, headers, body, SystemTime::now())
}

/// [`verify_webhook`] as if it were `now`.
pub fn verify_webhook_at<I, K, V>(
    secret: &str,
    headers: I,
    body: &[u8],
    now: SystemTime,
) -> Result<WebhookEvent, WebhookError>
where
    I: IntoIterator<Item = (K, V)>,
    K: AsRef<str>,
    V: AsRef<[u8]>,
{
    if secret.is_empty() {
        return Err(WebhookError::InvalidSecret);
    }
    let (mut delivery, mut stamp, mut signatures) = (None, None, Vec::new());
    for (name, value) in headers {
        let Ok(value) = std::str::from_utf8(value.as_ref()) else {
            continue;
        };
        let name = name.as_ref();
        if name.eq_ignore_ascii_case(WEBHOOK_HEADER_DELIVERY_ID) {
            delivery = delivery.or(Some(value.trim().to_owned()));
        } else if name.eq_ignore_ascii_case(WEBHOOK_HEADER_TIMESTAMP) {
            stamp = stamp.or(Some(value.trim().to_owned()));
        } else if name.eq_ignore_ascii_case(WEBHOOK_HEADER_SIGNATURE) {
            signatures.push(value.to_owned());
        }
    }
    let delivery = delivery
        .filter(|delivery| !delivery.is_empty())
        .ok_or(WebhookError::InvalidSignature)?;
    let stamp = stamp
        .filter(|stamp| !stamp.is_empty() && stamp.bytes().all(|byte| byte.is_ascii_digit()))
        .ok_or(WebhookError::InvalidSignature)?;
    let seconds: i64 = stamp.parse().map_err(|_| WebhookError::InvalidSignature)?;
    let now = match now.duration_since(UNIX_EPOCH) {
        Ok(since) => i64::try_from(since.as_secs()).unwrap_or(i64::MAX),
        Err(before) => -i64::try_from(before.duration().as_secs()).unwrap_or(i64::MAX),
    };
    if now.abs_diff(seconds) > WEBHOOK_TOLERANCE.as_secs() {
        return Err(WebhookError::InvalidSignature);
    }
    let signature = signatures.join(",");
    let entries: Vec<&str> = signature.split(',').collect();
    if signature.trim().is_empty() || entries.len() > MAX_SIGNATURES {
        return Err(WebhookError::InvalidSignature);
    }
    let given = entries
        .iter()
        .map(|entry| entry.trim().strip_prefix("sha256=").and_then(hex))
        .collect::<Option<Vec<_>>>()
        .ok_or(WebhookError::InvalidSignature)?;
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes())
        .map_err(|_| WebhookError::InvalidSecret)?;
    mac.update(format!("{stamp}.{delivery}.").as_bytes());
    mac.update(body);
    let mut matched = false;
    for each in &given {
        // verify_slice compares in constant time.
        matched |= mac.clone().verify_slice(each).is_ok();
    }
    if !matched {
        return Err(WebhookError::InvalidSignature);
    }
    serde_json::from_slice(body).map_err(WebhookError::InvalidPayload)
}

/// The 32 bytes 64 hexadecimal digits write, or None.
fn hex(text: &str) -> Option<Vec<u8>> {
    if text.len() != 64 || !text.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    (0..64)
        .step_by(2)
        .map(|at| u8::from_str_radix(&text[at..at + 2], 16).ok())
        .collect()
}
