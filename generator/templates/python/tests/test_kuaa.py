import json
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from kuaa import Kuaa, KuaaError, KuaaFile, WEBHOOK_TOLERANCE_SECONDS, WebhookVerificationError, verify_webhook

CASE = {
    "id": "case_1", "external_reference": "pedido-1", "kind": "KYC", "status": "open", "status_market": "PROCESSING", "livemode": False,
    "custom_status": None, "current_state": "collect_identity", "workflow_definition_id": None, "policy_version_id": None,
    "parent_case_id": None, "child_group": None, "parties": [{"id": "party_1", "kind": "PERSON", "primary": True, "identity_id": None, "cpf": "12345678909"}],
    "relationships": [], "created_at": "2027-01-15T08:00:00Z", "updated_at": "2027-01-15T08:00:00Z",
}


def summary(identifier):
    return {
        "id": identifier, "external_reference": f"ref-{identifier}", "kind": "KYC", "status": "open", "status_market": "PROCESSING",
        "livemode": False, "current_state": "start", "workflow_definition_id": None, "workflow_version_id": None,
        "policy_version_id": None, "created_at": "2027-01-15T08:00:00Z", "updated_at": "2027-01-15T08:00:00Z",
    }


class Recorder:
    def __init__(self, answer):
        self.answer = answer
        self.seen = []

    def __call__(self, method, url, headers, body, timeout):
        request = {"method": method, "url": urlparse(url), "headers": headers, "body": body}
        self.seen.append(request)
        status, payload, extra = self.answer(request)
        return status, extra, b"" if payload is None else json.dumps(payload).encode()


def client(answer):
    recorder = Recorder(answer)
    return Kuaa("kuaa_test_abc_secret", base_url="http://kuaa.test/", transport=recorder), recorder


class KuaaTest(unittest.TestCase):
    def test_a_call_carries_the_key_and_unwraps_the_data(self):
        kuaa, recorder = client(lambda request: (200, {"data": CASE}, {"kuaa-livemode": "false", "kuaa-environment": "sandbox", "x-request-id": "req_1"}))
        got = kuaa.cases.get("case_1")
        self.assertEqual((got.id, got.status, got.parties[0].cpf), ("case_1", "open", "12345678909"))
        seen = recorder.seen[0]
        self.assertEqual((seen["method"], seen["url"].path), ("GET", "/v1/cases/case_1"))
        self.assertEqual(seen["headers"]["Authorization"], "Bearer kuaa_test_abc_secret")
        last = kuaa.last_response
        self.assertIsNotNone(last)
        assert last is not None
        self.assertEqual((last.status, last.livemode, last.environment, last.idempotent_replayed, last.request_id), (200, False, "sandbox", False, "req_1"))

    def test_a_write_sends_its_body_and_idempotency_key(self):
        kuaa, recorder = client(lambda request: (200, {"data": CASE, "meta": {"created": False}}, {"idempotent-replayed": "true"}))
        got = kuaa.cases.create({"external_reference": "pedido-1", "kind": "KYC"}, idempotency_key="pedido-1")
        self.assertEqual(got.external_reference, "pedido-1")
        seen = recorder.seen[0]
        self.assertEqual((seen["method"], seen["url"].path), ("POST", "/v1/cases"))
        self.assertEqual(seen["headers"]["Idempotency-Key"], "pedido-1")
        self.assertEqual(seen["headers"]["Content-Type"], "application/json")
        self.assertEqual(json.loads(seen["body"]), {"external_reference": "pedido-1", "kind": "KYC"})
        self.assertTrue(kuaa.last_response and kuaa.last_response.idempotent_replayed)

    def test_iterating_walks_every_page_by_cursor(self):
        following = {"": "c2", "c2": "c3", "c3": None}
        ids = {"": "case_1", "c2": "case_2", "c3": "case_3"}

        def answer(request):
            query = parse_qs(request["url"].query)
            self.assertEqual((query["limit"], query["status"]), (["1"], ["open"]))
            cursor = query.get("cursor", [""])[0]
            meta = {"next_cursor": following[cursor], "has_more": following[cursor] is not None, "limit": 1}
            return 200, {"data": {"livemode": False, "cases": [summary(ids[cursor])]}, "meta": meta}, {}

        kuaa, recorder = client(answer)
        self.assertEqual([item.id for item in kuaa.cases.list_iter(limit=1, status="open")], ["case_1", "case_2", "case_3"])
        self.assertEqual(len(recorder.seen), 3)

    def test_a_refusal_is_a_typed_error(self):
        def answer(request):
            if request["url"].path == "/v1/cases":
                problem = {"code": "validation_failed", "message": "The input has invalid fields.", "fields": {"kind": ["must be KYC, KYB or AGE"]}}
                return 422, {"error": problem}, {}
            return 429, {"error": {"code": "rate_limited", "message": "Too many requests."}}, {"retry-after": "7"}

        kuaa, _ = client(answer)
        with self.assertRaises(KuaaError) as refused:
            kuaa.cases.create({"external_reference": "x", "kind": "KYC"})
        self.assertEqual((refused.exception.status, refused.exception.code), (422, "validation_failed"))
        self.assertEqual(refused.exception.fields["kind"], ["must be KYC, KYB or AGE"])
        with self.assertRaises(KuaaError) as limited:
            kuaa.cases.get("case_1")
        self.assertEqual((limited.exception.status, limited.exception.code, limited.exception.retry_after), (429, "rate_limited", 7))

    def test_a_capture_is_sent_as_multipart(self):
        document = {"id": "doc_1", "capture": "document", "party_id": "party_1", "status": "received", "artifact_id": None, "created_at": "2027-01-15T08:00:00Z"}
        kuaa, recorder = client(lambda request: (201, {"data": {"documents": [document]}}, {}))
        got = kuaa.case_media.create(
            "case_1",
            {
                "kind": "document",
                "document_type": "CNH",
                "side": "front",
                "file": [KuaaFile("frente.jpg", b"\xff\xd8 frente", "image/jpeg"), KuaaFile("verso.jpg", b"verso", "image/jpeg")],
            },
            idempotency_key="captura-1",
        )
        self.assertEqual(got.documents[0].id, "doc_1")
        seen = recorder.seen[0]
        self.assertEqual(seen["url"].path, "/v1/cases/case_1/media")
        self.assertEqual(seen["headers"]["Idempotency-Key"], "captura-1")
        content_type = seen["headers"]["Content-Type"]
        self.assertTrue(content_type.startswith("multipart/form-data; boundary="))
        boundary = content_type.split("boundary=", 1)[1].encode()
        body = seen["body"]
        self.assertIn(b'Content-Disposition: form-data; name="kind"\r\n\r\ndocument\r\n', body)
        self.assertIn(b'Content-Disposition: form-data; name="file"; filename="frente.jpg"\r\nContent-Type: image/jpeg\r\n\r\n\xff\xd8 frente\r\n', body)
        self.assertIn(b'filename="verso.jpg"', body)
        self.assertNotIn(b'name="party_id"', body)
        self.assertTrue(body.endswith(b"--" + boundary + b"--\r\n"))

    def test_a_list_query_repeats_its_name(self):
        kuaa, recorder = client(lambda request: (200, {"data": {"case_id": "case_1", "tags": []}}, {}))
        got = kuaa.case_tags.delete("case_1", tag=["prioridade", "revisar"])
        self.assertEqual(got.case_id, "case_1")
        self.assertEqual((recorder.seen[0]["method"], recorder.seen[0]["url"].query), ("DELETE", "tag=prioridade&tag=revisar"))

    def test_the_webhook_vectors(self):
        """The vectors are generated once, in Go, by sdk/generator, and every SDK checks its verification against them."""
        vectors = json.loads((Path(__file__).parent / "webhook-vectors.json").read_text(encoding="utf-8"))
        self.assertEqual(vectors["tolerance_seconds"], WEBHOOK_TOLERANCE_SECONDS)
        self.assertTrue(vectors["vectors"])
        for vector in vectors["vectors"]:
            with self.subTest(vector["name"]):
                body = vector["body"].encode("utf-8")
                if not vector["valid"]:
                    with self.assertRaises(WebhookVerificationError):
                        verify_webhook(vector["secret"], vector["headers"], body, now=vector["now"])
                    continue
                event = verify_webhook(vector["secret"], vector["headers"], body, now=vector["now"])
                want = vector["event"]
                self.assertEqual(event.specversion, "1.0")
                self.assertEqual(
                    (event.id, event.type, event.source, event.subject, event.data.case_id, event.data.status, event.data.environment, event.data.livemode),
                    (want["id"], want["type"], want["source"], want["subject"], want["case_id"], want["status"], want["environment"], want["livemode"]),
                )


if __name__ == "__main__":
    unittest.main()
