use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use std::sync::Mutex;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use ureq::RequestExt;

use crate::error::{ApiError, Error};
use crate::pagination::Page;
use crate::version::{DEFAULT_BASE_URL, VERSION};

/// Any error a [`Transport`] answers.
pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// One request, as a [`Transport`] sends it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct HttpRequest {
    /// GET, POST…
    pub method: String,
    /// The whole address, with the query.
    pub url: String,
    /// The headers, in the order they are sent.
    pub headers: Vec<(String, String)>,
    /// The body of a write, if it has one: JSON, or a multipart form.
    pub body: Option<Vec<u8>>,
    /// How long the call may take.
    pub timeout: Duration,
}

impl HttpRequest {
    /// The first value of a header, its name in any case.
    pub fn header(&self, name: &str) -> Option<&str> {
        find(&self.headers, name)
    }
}

/// One answer, as a [`Transport`] reads it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HttpResponse {
    /// The HTTP status.
    pub status: u16,
    /// The headers.
    pub headers: Vec<(String, String)>,
    /// The body.
    pub body: Vec<u8>,
}

impl HttpResponse {
    /// An answer with this status and body and no headers.
    pub fn new(status: u16, body: impl Into<Vec<u8>>) -> Self {
        Self {
            status,
            headers: Vec::new(),
            body: body.into(),
        }
    }

    /// The same answer with one more header.
    pub fn with_header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    /// The first value of a header, its name in any case.
    pub fn header(&self, name: &str) -> Option<&str> {
        find(&self.headers, name)
    }
}

fn find<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

/// Sends a request and answers what came back, whatever its status. The SDK
/// sends through [`UreqTransport`]; a test, or a program with its own HTTP
/// client, gives another one to [`ClientBuilder::transport`]. A function
/// from [`HttpRequest`] to `Result<HttpResponse, BoxError>` is one.
pub trait Transport: Send + Sync {
    /// Sends one request.
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, BoxError>;
}

impl<F> Transport for F
where
    F: Fn(HttpRequest) -> Result<HttpResponse, BoxError> + Send + Sync,
{
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, BoxError> {
        self(request)
    }
}

/// The HTTP the SDK sends through: [ureq](https://docs.rs/ureq), blocking,
/// with rustls.
#[derive(Debug, Clone)]
pub struct UreqTransport {
    agent: ureq::Agent,
}

impl UreqTransport {
    /// A transport with its own connection pool.
    pub fn new() -> Self {
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .build()
            .new_agent();
        Self { agent }
    }
}

impl Default for UreqTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl Transport for UreqTransport {
    fn send(&self, request: HttpRequest) -> Result<HttpResponse, BoxError> {
        let mut builder = ureq::http::Request::builder()
            .method(request.method.as_str())
            .uri(request.url.as_str());
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        let timeout = Some(request.timeout);
        let mut response = match request.body {
            Some(body) => builder
                .body(body)?
                .with_agent(&self.agent)
                .configure()
                .timeout_global(timeout)
                .run()?,
            None => builder
                .body(())?
                .with_agent(&self.agent)
                .configure()
                .timeout_global(timeout)
                .run()?,
        };
        let headers = response
            .headers()
            .iter()
            .filter_map(|(name, value)| {
                Some((name.as_str().to_owned(), value.to_str().ok()?.to_owned()))
            })
            .collect();
        let status = response.status().as_u16();
        let body = response.body_mut().read_to_vec()?;
        Ok(HttpResponse {
            status,
            headers,
            body,
        })
    }
}

/// Options of one call: the key it is made with and, for a write, the key
/// that makes it safe to repeat.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RequestOptions {
    /// Makes a write safe to repeat: the same key with the same request
    /// answers the first response again; with another request, a 409.
    pub idempotency_key: Option<String>,
    /// Sends the call with another key.
    pub api_key: Option<String>,
}

/// One file of a multipart body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FilePart {
    /// The name the part carries, such as frente.jpg.
    pub filename: String,
    /// The file's bytes.
    pub data: Vec<u8>,
    /// The file's media type: image/jpeg or image/png.
    pub content_type: String,
}

impl FilePart {
    /// A file with its name, bytes and media type.
    pub fn new(
        filename: impl Into<String>,
        data: impl Into<Vec<u8>>,
        content_type: impl Into<String>,
    ) -> Self {
        Self {
            filename: filename.into(),
            data: data.into(),
            content_type: content_type.into(),
        }
    }
}

/// One field of a multipart body: a text value, or a file.
#[derive(Debug, Clone)]
pub(crate) enum Part {
    Text(String),
    File(FilePart),
}

/// What the API said about an answer, beside its body.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct ResponseInfo {
    /// The HTTP status.
    pub status: u16,
    /// The Kuaa-Livemode header: true for live, false for a sandbox, None
    /// when absent.
    pub livemode: Option<bool>,
    /// The Kuaa-Environment header: live or sandbox.
    pub environment: Option<String>,
    /// The answer is the stored answer of an earlier request with the same
    /// Idempotency-Key.
    pub idempotent_replayed: bool,
    /// The X-Request-ID header.
    pub request_id: Option<String>,
}

impl ResponseInfo {
    fn of(response: &HttpResponse) -> Self {
        Self {
            status: response.status,
            livemode: match response.header("kuaa-livemode") {
                Some("true") => Some(true),
                Some("false") => Some(false),
                _ => None,
            },
            environment: response.header("kuaa-environment").map(str::to_owned),
            idempotent_replayed: response.header("idempotent-replayed") == Some("true"),
            request_id: response.header("x-request-id").map(str::to_owned),
        }
    }
}

/// KUAA's API with one organization's API key. The key says the
/// organization and the environment: `kuaa_<prefix>_<secret>` is live,
/// `kuaa_test_<prefix>_<secret>` the organization's sandbox.
///
/// A client is cheap to clone, and its clones share one connection pool and
/// one [`last_response`](Client::last_response).
#[derive(Clone)]
pub struct Client {
    api_key: String,
    base_url: String,
    timeout: Duration,
    transport: Arc<dyn Transport>,
    last: Arc<Mutex<Option<ResponseInfo>>>,
}

impl fmt::Debug for Client {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Client")
            .field("base_url", &self.base_url)
            .field("timeout", &self.timeout)
            .finish_non_exhaustive()
    }
}

/// Configures a [`Client`].
pub struct ClientBuilder {
    api_key: String,
    base_url: String,
    timeout: Duration,
    transport: Option<Arc<dyn Transport>>,
}

impl fmt::Debug for ClientBuilder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClientBuilder")
            .field("base_url", &self.base_url)
            .field("timeout", &self.timeout)
            .finish_non_exhaustive()
    }
}

impl ClientBuilder {
    /// Points the client at another address, such as a local server.
    pub fn base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = base_url.into().trim_end_matches('/').to_owned();
        self
    }

    /// How long a call may take; 30 seconds by default.
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Sends the requests through `transport`.
    pub fn transport(mut self, transport: impl Transport + 'static) -> Self {
        self.transport = Some(Arc::new(transport));
        self
    }

    /// The client.
    pub fn build(self) -> Client {
        Client {
            api_key: self.api_key,
            base_url: self.base_url,
            timeout: self.timeout,
            transport: self
                .transport
                .unwrap_or_else(|| Arc::new(UreqTransport::new())),
            last: Arc::default(),
        }
    }
}

impl Client {
    /// A client for the organization `api_key` belongs to.
    pub fn new(api_key: impl Into<String>) -> Self {
        Self::builder(api_key).build()
    }

    /// Configures a client for the organization `api_key` belongs to.
    pub fn builder(api_key: impl Into<String>) -> ClientBuilder {
        ClientBuilder {
            api_key: api_key.into(),
            base_url: DEFAULT_BASE_URL.to_owned(),
            timeout: Duration::from_secs(30),
            transport: None,
        }
    }

    /// What the API said about the last answer this client (or a clone of
    /// it) read, or None before the first one.
    pub fn last_response(&self) -> Option<ResponseInfo> {
        self.last.lock().ok().and_then(|last| last.clone())
    }

    /// Calls the API and answers its envelope; a refusal is [`Error::Api`].
    /// `body` is the bytes and their Content-Type.
    pub(crate) fn send(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, String)],
        body: Option<(Vec<u8>, String)>,
        options: &RequestOptions,
    ) -> Result<serde_json::Value, Error> {
        let mut url = format!("{}{}", self.base_url, path);
        let pairs: Vec<String> = query
            .iter()
            .filter(|(_, value)| !value.is_empty())
            .map(|(name, value)| format!("{}={}", escape(name), escape(value)))
            .collect();
        if !pairs.is_empty() {
            url.push('?');
            url.push_str(&pairs.join("&"));
        }
        let api_key = options.api_key.as_deref().unwrap_or(&self.api_key);
        let mut headers = vec![
            ("Authorization".to_owned(), format!("Bearer {api_key}")),
            ("Accept".to_owned(), "application/json".to_owned()),
            ("User-Agent".to_owned(), format!("kuaa-rust/{VERSION}")),
        ];
        let body = body.map(|(bytes, content_type)| {
            headers.push(("Content-Type".to_owned(), content_type));
            bytes
        });
        if let Some(key) = options
            .idempotency_key
            .as_deref()
            .filter(|key| !key.is_empty())
        {
            headers.push(("Idempotency-Key".to_owned(), key.to_owned()));
        }
        let request = HttpRequest {
            method: method.to_owned(),
            url,
            headers,
            body,
            timeout: self.timeout,
        };
        let response = self.transport.send(request).map_err(Error::Transport)?;
        if let Ok(mut last) = self.last.lock() {
            *last = Some(ResponseInfo::of(&response));
        }
        if response.status >= 300 {
            return Err(ApiError::from_response(&response).into());
        }
        serde_json::from_slice(&response.body).map_err(Error::Json)
    }

    /// Calls the API and answers its `data`.
    pub(crate) fn request<T: DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, String)],
        body: Option<(Vec<u8>, String)>,
        options: &RequestOptions,
    ) -> Result<T, Error> {
        let mut envelope = self.send(method, path, query, body, options)?;
        let data = envelope
            .get_mut("data")
            .map(serde_json::Value::take)
            .unwrap_or_default();
        serde_json::from_value(data).map_err(Error::Json)
    }

    /// Calls a list and answers its page, the items under `field`.
    pub(crate) fn page<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, String)],
        field: &str,
        options: &RequestOptions,
    ) -> Result<Page<T>, Error> {
        let mut envelope = self.send("GET", path, query, None, options)?;
        let items = envelope
            .get_mut("data")
            .and_then(|data| data.get_mut(field))
            .map(serde_json::Value::take)
            .filter(|items| !items.is_null())
            .unwrap_or_else(|| serde_json::Value::Array(Vec::new()));
        let meta = envelope.get("meta");
        let next_cursor = meta
            .and_then(|meta| meta.get("next_cursor"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned);
        let has_more = meta
            .and_then(|meta| meta.get("has_more"))
            .and_then(serde_json::Value::as_bool)
            .unwrap_or_else(|| next_cursor.as_deref().is_some_and(|next| !next.is_empty()));
        Ok(Page {
            items: serde_json::from_value(items).map_err(Error::Json)?,
            next_cursor,
            has_more,
        })
    }
}

/// A JSON body and its Content-Type.
pub(crate) fn json<B: Serialize + ?Sized>(body: &B) -> Result<Option<(Vec<u8>, String)>, Error> {
    let bytes = serde_json::to_vec(body).map_err(Error::Json)?;
    Ok(Some((bytes, "application/json".to_owned())))
}

/// A multipart/form-data body and its Content-Type: a text value per field,
/// or a file.
pub(crate) fn multipart(parts: &[(&str, Part)]) -> Option<(Vec<u8>, String)> {
    let boundary = format!("kuaa-{}", boundary_token());
    let quote = |text: &str| {
        text.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\r', "%0D")
            .replace('\n', "%0A")
    };
    let mut out = Vec::new();
    for (name, part) in parts {
        out.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
        match part {
            Part::File(file) => {
                out.extend_from_slice(
                    format!(
                        "Content-Disposition: form-data; name=\"{}\"; filename=\"{}\"\r\nContent-Type: {}\r\n\r\n",
                        quote(name),
                        quote(&file.filename),
                        file.content_type
                    )
                    .as_bytes(),
                );
                out.extend_from_slice(&file.data);
            }
            Part::Text(text) => {
                out.extend_from_slice(
                    format!(
                        "Content-Disposition: form-data; name=\"{}\"\r\n\r\n{text}",
                        quote(name)
                    )
                    .as_bytes(),
                );
            }
        }
        out.extend_from_slice(b"\r\n");
    }
    out.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
    Some((out, format!("multipart/form-data; boundary={boundary}")))
}

/// 24 hexadecimal digits that differ from one body to the next, from the
/// clock and a counter: a boundary has to be unlikely to appear in the
/// files, not secret.
fn boundary_token() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| since.as_nanos())
        .unwrap_or_default();
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    std::hash::Hash::hash(&(nanos, count, std::process::id()), &mut hasher);
    format!(
        "{:016x}{:08x}",
        std::hash::Hasher::finish(&hasher),
        count as u32
    )
}

/// A path parameter or a query value, escaped: everything but letters,
/// digits and `-._~`.
pub(crate) fn escape(value: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            out.push('%');
            out.push(HEX[usize::from(byte >> 4)] as char);
            out.push(HEX[usize::from(byte & 15)] as char);
        }
    }
    out
}
