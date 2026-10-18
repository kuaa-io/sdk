use std::collections::HashMap;
use std::fmt;
use std::time::Duration;

use serde::Deserialize;

use crate::client::{BoxError, HttpResponse};

/// What a call answers instead of its resource.
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// The API refused the request.
    Api(Box<ApiError>),
    /// The request did not reach the API, or its answer did not arrive.
    Transport(BoxError),
    /// A body could not be written as JSON, or the API answered something
    /// this SDK does not read.
    Json(serde_json::Error),
}

/// A request the API refused.
///
/// `code` is the API's, the one to branch on: unauthenticated, forbidden,
/// not_found, conflict, idempotency_key_reused, validation_failed,
/// payment_required, malformed_json, body_too_large, rate_limited…
/// `fields` says, for validation_failed, what is wrong with each field.
/// `retry_after` is how long the API asked to wait, on a 429 or a 503.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct ApiError {
    /// The HTTP status.
    pub status: u16,
    /// The API's code for the refusal.
    pub code: String,
    /// What went wrong, for a person to read.
    pub message: String,
    /// The problems of each field of the request.
    pub fields: HashMap<String, Vec<String>>,
    /// How long to wait before trying again.
    pub retry_after: Option<Duration>,
    /// The X-Request-ID header.
    pub request_id: Option<String>,
}

#[derive(Deserialize, Default)]
struct ErrorBody {
    error: Option<Problem>,
}

#[derive(Deserialize, Default)]
struct Problem {
    code: Option<String>,
    message: Option<String>,
    fields: Option<HashMap<String, Vec<String>>>,
}

impl ApiError {
    /// The error a refused response carries. A refusal without a JSON body is
    /// still a refusal.
    pub(crate) fn from_response(response: &HttpResponse) -> Self {
        let body: ErrorBody = serde_json::from_slice(&response.body).unwrap_or_default();
        let problem = body.error.unwrap_or_default();
        Self {
            status: response.status,
            code: problem.code.unwrap_or_default(),
            message: problem.message.unwrap_or_default(),
            fields: problem.fields.unwrap_or_default(),
            retry_after: response
                .header("retry-after")
                .and_then(|value| value.trim().parse::<u64>().ok())
                .map(Duration::from_secs),
            request_id: response.header("x-request-id").map(str::to_owned),
        }
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.message.is_empty() {
            write!(f, "kuaa: {} {}", self.status, self.code)
        } else {
            write!(f, "kuaa: {} {}: {}", self.status, self.code, self.message)
        }
    }
}

impl std::error::Error for ApiError {}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Api(error) => error.fmt(f),
            Error::Transport(error) => write!(f, "kuaa: {error}"),
            Error::Json(error) => write!(f, "kuaa: json: {error}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Api(error) => Some(error.as_ref()),
            Error::Transport(error) => Some(error.as_ref()),
            Error::Json(error) => Some(error),
        }
    }
}

impl From<ApiError> for Error {
    fn from(error: ApiError) -> Self {
        Error::Api(Box::new(error))
    }
}

impl Error {
    /// The refusal, when the API refused the request.
    pub fn api(&self) -> Option<&ApiError> {
        match self {
            Error::Api(error) => Some(error.as_ref()),
            _ => None,
        }
    }
}
