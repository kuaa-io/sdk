use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};

use kuaa::{
    verify_webhook_at, BoxError, CaptureForm, CaptureFormKind, CaseRequest, CaseRequestKind,
    CaseRequestParty, CaseRequestPartyKind, CaseStatus, CaseTagsDeleteParams, CaseTagsRequest,
    CasesListParams, Client, Error, FilePart, HttpRequest, HttpResponse, WebhookError,
    WEBHOOK_TOLERANCE,
};

type Seen = Arc<Mutex<Vec<HttpRequest>>>;

fn client(answer: impl Fn(&HttpRequest) -> HttpResponse + Send + Sync + 'static) -> (Client, Seen) {
    let seen: Seen = Arc::default();
    let record = Arc::clone(&seen);
    let transport = move |request: HttpRequest| -> Result<HttpResponse, BoxError> {
        let response = answer(&request);
        record.lock().unwrap().push(request);
        Ok(response)
    };
    let client = Client::builder("kuaa_test_abc_secret")
        .base_url("http://kuaa.test/")
        .transport(transport)
        .build();
    (client, seen)
}

fn kase() -> serde_json::Value {
    serde_json::json!({
        "id": "case_1", "external_reference": "pedido-1", "kind": "KYC", "status": "open",
        "status_market": "PROCESSING", "livemode": false, "custom_status": null,
        "current_state": "collect_identity", "workflow_definition_id": null, "policy_version_id": null,
        "parent_case_id": null, "child_group": null,
        "parties": [{"id": "party_1", "kind": "PERSON", "primary": true, "identity_id": null, "cpf": "12345678909"}],
        "relationships": [], "created_at": "2027-01-15T08:00:00Z", "updated_at": "2027-01-15T08:00:00Z"
    })
}

fn summary(id: &str) -> serde_json::Value {
    serde_json::json!({
        "id": id, "external_reference": format!("ref-{id}"), "kind": "KYC", "status": "open",
        "status_market": "PROCESSING", "livemode": false, "current_state": "start",
        "workflow_definition_id": null, "workflow_version_id": null, "policy_version_id": null,
        "created_at": "2027-01-15T08:00:00Z", "updated_at": "2027-01-15T08:00:00Z"
    })
}

fn json(status: u16, body: serde_json::Value) -> HttpResponse {
    HttpResponse::new(status, body.to_string()).with_header("Content-Type", "application/json")
}

fn query(url: &str, name: &str) -> Option<String> {
    let (_, query) = url.split_once('?')?;
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == name).then(|| value.to_owned())
    })
}

#[test]
fn a_call_carries_the_key_and_unwraps_the_data() {
    let (client, seen) = client(|_| {
        json(200, serde_json::json!({"data": kase()}))
            .with_header("Kuaa-Livemode", "false")
            .with_header("Kuaa-Environment", "sandbox")
            .with_header("X-Request-ID", "req_1")
    });
    let got = client.cases().get("case_1").unwrap();
    assert_eq!(got.id, "case_1");
    assert_eq!(got.status, CaseStatus::Open);
    assert_eq!(got.parties[0].cpf.as_deref(), Some("12345678909"));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "GET");
    assert_eq!(seen[0].url, "http://kuaa.test/v1/cases/case_1");
    assert_eq!(
        seen[0].header("authorization"),
        Some("Bearer kuaa_test_abc_secret")
    );
    assert_eq!(
        seen[0].header("user-agent"),
        Some(format!("kuaa-rust/{}", kuaa::VERSION).as_str())
    );
    let last = client.last_response().unwrap();
    assert_eq!(last.status, 200);
    assert_eq!(last.livemode, Some(false));
    assert_eq!(last.environment.as_deref(), Some("sandbox"));
    assert!(!last.idempotent_replayed);
    assert_eq!(last.request_id.as_deref(), Some("req_1"));
}

#[test]
fn a_write_sends_its_body_and_idempotency_key() {
    let (client, seen) = client(|_| {
        json(
            200,
            serde_json::json!({"data": kase(), "meta": {"created": false}}),
        )
        .with_header("Idempotent-Replayed", "true")
    });
    let got = client
        .cases()
        .idempotency_key("pedido-1")
        .create(&CaseRequest::new("pedido-1", CaseRequestKind::Kyc))
        .unwrap();
    assert_eq!(got.external_reference, "pedido-1");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "POST");
    assert_eq!(seen[0].url, "http://kuaa.test/v1/cases");
    assert_eq!(seen[0].header("idempotency-key"), Some("pedido-1"));
    assert_eq!(seen[0].header("content-type"), Some("application/json"));
    let body: serde_json::Value = serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
    // The optional fields, left unset, are not sent.
    assert_eq!(
        body,
        serde_json::json!({"external_reference": "pedido-1", "kind": "KYC"})
    );
    assert!(client.last_response().unwrap().idempotent_replayed);
}

#[test]
fn a_nested_body_is_written_whole() {
    let (client, seen) = client(|_| json(201, serde_json::json!({"data": kase()})));
    let party = CaseRequestParty::new(CaseRequestPartyKind::Person)
        .primary(true)
        .cpf("123.456.789-09");
    client
        .cases()
        .create(&CaseRequest::new("pedido-1", CaseRequestKind::Kyc).parties(vec![party]))
        .unwrap();
    let seen = seen.lock().unwrap();
    let body: serde_json::Value = serde_json::from_slice(seen[0].body.as_deref().unwrap()).unwrap();
    assert_eq!(
        body,
        serde_json::json!({"external_reference": "pedido-1", "kind": "KYC",
            "parties": [{"cpf": "123.456.789-09", "kind": "PERSON", "primary": true}]})
    );
}

#[test]
fn iterating_walks_every_page_by_cursor() {
    let (client, seen) = client(|request| {
        assert_eq!(query(&request.url, "limit").as_deref(), Some("1"));
        assert_eq!(query(&request.url, "status").as_deref(), Some("open"));
        let cursor = query(&request.url, "cursor").unwrap_or_default();
        let (id, next) = match cursor.as_str() {
            "" => ("case_1", Some("c2")),
            "c2" => ("case_2", Some("c3")),
            _ => ("case_3", None),
        };
        json(
            200,
            serde_json::json!({
                "data": {"livemode": false, "cases": [summary(id)]},
                "meta": {"next_cursor": next, "has_more": next.is_some(), "limit": 1}
            }),
        )
    });
    let ids: Vec<String> = client
        .cases()
        .list_iter(CasesListParams::new().limit(1).status("open"))
        .map(|summary| summary.unwrap().id)
        .collect();
    assert_eq!(ids, ["case_1", "case_2", "case_3"]);
    assert_eq!(seen.lock().unwrap().len(), 3);
}

#[test]
fn a_refusal_is_a_typed_error() {
    let (client, _) = client(|request| {
        if request.url.ends_with("/v1/cases") {
            json(
                422,
                serde_json::json!({"error": {"code": "validation_failed", "message": "The input has invalid fields.",
                    "fields": {"kind": ["must be KYC, KYB or AGE"]}}}),
            )
        } else {
            json(
                429,
                serde_json::json!({"error": {"code": "rate_limited", "message": "Too many requests."}}),
            )
            .with_header("Retry-After", "7")
        }
    });
    let Err(Error::Api(refused)) = client
        .cases()
        .create(&CaseRequest::new("x", CaseRequestKind::Kyc))
    else {
        panic!("a 422 was not refused");
    };
    assert_eq!(refused.status, 422);
    assert_eq!(refused.code, "validation_failed");
    assert_eq!(refused.fields["kind"], ["must be KYC, KYB or AGE"]);
    let Err(Error::Api(limited)) = client.cases().get("case_1") else {
        panic!("a 429 was not refused");
    };
    assert_eq!(limited.status, 429);
    assert_eq!(limited.code, "rate_limited");
    assert_eq!(limited.retry_after, Some(Duration::from_secs(7)));
}

#[test]
fn a_capture_is_sent_as_multipart() {
    let (client, seen) = client(|_| {
        json(
            201,
            serde_json::json!({"data": {"documents": [{"id": "doc_1", "capture": "document", "party_id": "party_1",
                "status": "received", "artifact_id": null, "created_at": "2027-01-15T08:00:00Z"}]}}),
        )
    });
    let form = CaptureForm::new(
        vec![
            FilePart::new("frente.jpg", vec![0xff, 0xd8, b' ', b'f'], "image/jpeg"),
            FilePart::new("verso.jpg", b"verso".to_vec(), "image/jpeg"),
        ],
        CaptureFormKind::Document,
    )
    .document_type("CNH")
    .side("front");
    let got = client
        .case_media()
        .idempotency_key("captura-1")
        .create("case_1", &form)
        .unwrap();
    assert_eq!(got.documents[0].id, "doc_1");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].url, "http://kuaa.test/v1/cases/case_1/media");
    assert_eq!(seen[0].header("idempotency-key"), Some("captura-1"));
    let content_type = seen[0].header("content-type").unwrap();
    let boundary = content_type
        .strip_prefix("multipart/form-data; boundary=")
        .unwrap();
    let body = seen[0].body.as_deref().unwrap();
    let contains = |needle: &[u8]| body.windows(needle.len()).any(|window| window == needle);
    assert!(contains(
        b"Content-Disposition: form-data; name=\"kind\"\r\n\r\ndocument\r\n"
    ));
    assert!(contains(b"Content-Disposition: form-data; name=\"file\"; filename=\"frente.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n\xff\xd8 f\r\n"));
    assert!(contains(b"filename=\"verso.jpg\""));
    assert!(!contains(b"name=\"party_id\""));
    assert!(body.ends_with(format!("--{boundary}--\r\n").as_bytes()));
}

#[test]
fn a_list_query_repeats_its_name() {
    let (client, seen) = client(|_| {
        json(
            200,
            serde_json::json!({"data": {"case_id": "case_1", "tags": []}}),
        )
    });
    let got = client
        .case_tags()
        .delete(
            "case_1",
            &CaseTagsDeleteParams::new().tag(["prioridade", "revisar"]),
        )
        .unwrap();
    assert_eq!(got.case_id, "case_1");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].method, "DELETE");
    assert_eq!(
        seen[0].url,
        "http://kuaa.test/v1/cases/case_1/tags?tag=prioridade&tag=revisar"
    );
}

/// The vectors are generated once, in Go, by sdk/generator, and every SDK
/// checks its verification against them.
#[test]
fn the_webhook_vectors() {
    let raw = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/webhook-vectors.json"
    ))
    .unwrap();
    let vectors: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    assert_eq!(
        vectors["tolerance_seconds"].as_u64(),
        Some(WEBHOOK_TOLERANCE.as_secs())
    );
    let all = vectors["vectors"].as_array().unwrap();
    assert!(!all.is_empty());
    for vector in all {
        let name = vector["name"].as_str().unwrap();
        let mut headers = Vec::new();
        for (header, lines) in vector["headers"].as_object().unwrap() {
            for line in lines.as_array().unwrap() {
                headers.push((header.clone(), line.as_str().unwrap().to_owned()));
            }
        }
        let body = vector["body"].as_str().unwrap().as_bytes();
        let secret = vector["secret"].as_str().unwrap();
        let now = UNIX_EPOCH + Duration::from_secs(vector["now"].as_u64().unwrap());
        let result = verify_webhook_at(secret, headers, body, now);
        if vector["valid"] != true {
            assert!(
                matches!(result, Err(WebhookError::InvalidSignature)),
                "{name}: {result:?}"
            );
            continue;
        }
        let event = result.unwrap_or_else(|error| panic!("{name}: {error}"));
        let want = &vector["event"];
        assert_eq!(event.specversion.as_str(), "1.0", "{name}");
        assert_eq!(
            (
                event.id.as_str(),
                event.type_.as_str(),
                event.source.as_str(),
                event.subject.as_str(),
                event.data.case_id.as_str(),
                event.data.status.as_str(),
                event.data.environment.as_str(),
                event.data.livemode,
            ),
            (
                want["id"].as_str().unwrap(),
                want["type"].as_str().unwrap(),
                want["source"].as_str().unwrap(),
                want["subject"].as_str().unwrap(),
                want["case_id"].as_str().unwrap(),
                want["status"].as_str().unwrap(),
                want["environment"].as_str().unwrap(),
                want["livemode"].as_bool().unwrap(),
            ),
            "{name}"
        );
    }
}

/// Answers what it was sent as a case's tags; a request without the test key
/// is refused with a 401, Retry-After 3 and a request id.
fn echo_server() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut parts = line.split_whitespace();
            let (method, target) = (
                parts.next().unwrap_or("").to_owned(),
                parts.next().unwrap_or("").to_owned(),
            );
            let (mut length, mut authorization, mut idempotency) =
                (0, String::new(), String::new());
            loop {
                let mut header = String::new();
                reader.read_line(&mut header).unwrap();
                let header = header.trim_end();
                if header.is_empty() {
                    break;
                }
                let (name, value) = header.split_once(':').unwrap();
                match name.to_ascii_lowercase().as_str() {
                    "content-length" => length = value.trim().parse().unwrap(),
                    "authorization" => authorization = value.trim().to_owned(),
                    "idempotency-key" => idempotency = value.trim().to_owned(),
                    _ => {}
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let (status, extra, answer) = if authorization != "Bearer kuaa_test_abc_secret" {
                (
                    "401 Unauthorized",
                    "Retry-After: 3\r\nX-Request-ID: req_401\r\n",
                    serde_json::json!({"error": {"code": "unauthenticated", "message": "Send a key."}}),
                )
            } else {
                let sent: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
                let tags: Vec<serde_json::Value> = sent["tags"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .map(|name| {
                        serde_json::json!({"id": "tag_1", "name": name, "slug": idempotency,
                            "created_at": format!("{method} {target}")})
                    })
                    .collect();
                (
                    "200 OK",
                    "Kuaa-Livemode: false\r\n",
                    serde_json::json!({"data": {"case_id": "case_1", "tags": tags}}),
                )
            };
            let answer = answer.to_string();
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{answer}",
                answer.len()
            );
        }
    });
    format!("http://{address}")
}

#[test]
fn the_real_http_sends_and_reads_through_ureq() {
    let base_url = echo_server();
    let client = Client::builder("kuaa_test_abc_secret")
        .base_url(&base_url)
        .build();
    let tags = client
        .case_tags()
        .idempotency_key("tag-1")
        .create(
            "case 1/2",
            &CaseTagsRequest::new(vec!["prioridade".to_owned()]),
        )
        .unwrap();
    assert_eq!(tags.tags[0].name, "prioridade");
    assert_eq!(tags.tags[0].slug, "tag-1");
    assert_eq!(tags.tags[0].created_at, "POST /v1/cases/case%201%2F2/tags");
    assert_eq!(client.last_response().unwrap().livemode, Some(false));
    let other = Client::builder("kuaa_test_other")
        .base_url(&base_url)
        .build();
    let Err(Error::Api(refused)) = other.cases().get("case_1") else {
        panic!("a 401 was not refused");
    };
    assert_eq!(refused.status, 401);
    assert_eq!(refused.code, "unauthenticated");
    assert_eq!(refused.retry_after, Some(Duration::from_secs(3)));
    assert_eq!(refused.request_id.as_deref(), Some("req_401"));
}
