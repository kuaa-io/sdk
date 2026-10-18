package io.kuaa;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import org.junit.jupiter.api.Test;

class KuaaTest {
    private static final String CASE = "{\"id\":\"case_1\",\"external_reference\":\"pedido-1\",\"kind\":\"KYC\",\"status\":\"open\","
            + "\"status_market\":\"PROCESSING\",\"livemode\":false,\"custom_status\":null,\"current_state\":\"collect_identity\","
            + "\"workflow_definition_id\":null,\"policy_version_id\":null,\"parent_case_id\":null,\"child_group\":null,"
            + "\"parties\":[{\"id\":\"party_1\",\"kind\":\"PERSON\",\"primary\":true,\"identity_id\":null,\"cpf\":\"12345678909\"}],"
            + "\"relationships\":[],\"created_at\":\"2027-01-15T08:00:00Z\",\"updated_at\":\"2027-01-15T08:00:00Z\"}";

    private static String summary(String id) {
        return "{\"id\":\"" + id + "\",\"external_reference\":\"ref-" + id + "\",\"kind\":\"KYC\",\"status\":\"open\","
                + "\"status_market\":\"PROCESSING\",\"livemode\":false,\"current_state\":\"start\",\"workflow_definition_id\":null,"
                + "\"workflow_version_id\":null,\"policy_version_id\":null,\"created_at\":\"2027-01-15T08:00:00Z\","
                + "\"updated_at\":\"2027-01-15T08:00:00Z\"}";
    }

    /** A transport that records each request and answers what the test says. */
    private static final class Recorder implements Transport {
        final List<Request> seen = new ArrayList<>();
        private final Function<Request, Response> answer;

        Recorder(Function<Request, Response> answer) {
            this.answer = answer;
        }

        @Override
        public Response send(Request request) {
            seen.add(request);
            return answer.apply(request);
        }
    }

    private static Transport.Response json(int status, String body, String... headers) {
        Map<String, String> map = new LinkedHashMap<>();
        for (int i = 0; i < headers.length; i += 2) {
            map.put(headers[i], headers[i + 1]);
        }
        return new Transport.Response(status, map, body.getBytes(StandardCharsets.UTF_8));
    }

    private static Kuaa client(Recorder recorder) {
        return Kuaa.builder("kuaa_test_abc_secret").baseUrl("http://kuaa.test/").transport(recorder).build();
    }

    private static Map<String, String> query(Transport.Request request) {
        Map<String, String> out = new LinkedHashMap<>();
        String raw = URI.create(request.getUrl()).getRawQuery();
        if (raw != null) {
            for (String pair : raw.split("&")) {
                String[] parts = pair.split("=", 2);
                out.put(parts[0], parts.length > 1 ? parts[1] : "");
            }
        }
        return out;
    }

    @Test
    void aCallCarriesTheKeyAndUnwrapsTheData() {
        Recorder recorder = new Recorder(request -> json(200, "{\"data\":" + CASE + "}",
                "Kuaa-Livemode", "false", "Kuaa-Environment", "sandbox", "X-Request-ID", "req_1"));
        Kuaa kuaa = client(recorder);
        Case got = kuaa.cases().get("case_1");
        assertEquals("case_1", got.getId());
        assertEquals(Case.STATUS_OPEN, got.getStatus());
        assertEquals("12345678909", got.getParties().get(0).getCpf());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("GET", seen.getMethod());
        assertEquals("http://kuaa.test/v1/cases/case_1", seen.getUrl());
        assertEquals("Bearer kuaa_test_abc_secret", seen.getHeaders().get("Authorization"));
        ResponseInfo last = kuaa.getLastResponse();
        assertEquals(200, last.getStatus());
        assertEquals(Boolean.FALSE, last.getLivemode());
        assertEquals("sandbox", last.getEnvironment());
        assertFalse(last.isIdempotentReplayed());
        assertEquals("req_1", last.getRequestId());
    }

    @Test
    void aWriteSendsItsBodyAndIdempotencyKey() {
        Recorder recorder = new Recorder(request -> json(200, "{\"data\":" + CASE + ",\"meta\":{\"created\":false}}", "Idempotent-Replayed", "true"));
        Kuaa kuaa = client(recorder);
        Case got = kuaa.cases().create(CaseRequest.builder().externalReference("pedido-1").kind(CaseRequest.KIND_KYC).build(),
                RequestOptions.builder().idempotencyKey("pedido-1").build());
        assertEquals("pedido-1", got.getExternalReference());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("POST", seen.getMethod());
        assertEquals("http://kuaa.test/v1/cases", seen.getUrl());
        assertEquals("pedido-1", seen.getHeaders().get("Idempotency-Key"));
        assertEquals("application/json", seen.getHeaders().get("Content-Type"));
        assertEquals("{\"external_reference\":\"pedido-1\",\"kind\":\"KYC\"}", new String(seen.getBody(), StandardCharsets.UTF_8));
        assertTrue(kuaa.getLastResponse().isIdempotentReplayed());
        assertThrows(IllegalStateException.class, () -> CaseRequest.builder().kind("KYC").build());
    }

    @Test
    void aNestedBodyIsWrittenWhole() {
        Recorder recorder = new Recorder(request -> json(201, "{\"data\":" + CASE + "}"));
        client(recorder).cases().create(CaseRequest.builder().externalReference("pedido-1").kind("KYC")
                .parties(List.of(CaseRequestParty.builder().kind("PERSON").primary(true).cpf("123.456.789-09").build())).build());
        assertEquals("{\"external_reference\":\"pedido-1\",\"kind\":\"KYC\",\"parties\":[{\"cpf\":\"123.456.789-09\",\"kind\":\"PERSON\",\"primary\":true}]}",
                new String(recorder.seen.get(0).getBody(), StandardCharsets.UTF_8));
    }

    @Test
    void iteratingWalksEveryPageByCursor() {
        Map<String, String> following = Map.of("", "c2", "c2", "c3");
        Map<String, String> ids = Map.of("", "case_1", "c2", "case_2", "c3", "case_3");
        Recorder recorder = new Recorder(request -> {
            Map<String, String> values = query(request);
            assertEquals("1", values.get("limit"));
            assertEquals("open", values.get("status"));
            String cursor = values.getOrDefault("cursor", "");
            String next = following.get(cursor);
            String meta = next == null ? "{\"next_cursor\":null,\"has_more\":false,\"limit\":1}" : "{\"next_cursor\":\"" + next + "\",\"has_more\":true,\"limit\":1}";
            return json(200, "{\"data\":{\"livemode\":false,\"cases\":[" + summary(ids.get(cursor)) + "]},\"meta\":" + meta + "}");
        });
        List<String> walked = new ArrayList<>();
        for (CaseSummary each : client(recorder).cases().listIter(CasesService.ListParams.builder().limit(1).status("open").build())) {
            walked.add(each.getId());
        }
        assertEquals(List.of("case_1", "case_2", "case_3"), walked);
        assertEquals(3, recorder.seen.size());
    }

    @Test
    void aRefusalIsATypedError() {
        Recorder recorder = new Recorder(request -> request.getUrl().endsWith("/v1/cases")
                ? json(422, "{\"error\":{\"code\":\"validation_failed\",\"message\":\"The input has invalid fields.\",\"fields\":{\"kind\":[\"must be KYC, KYB or AGE\"]}}}")
                : json(429, "{\"error\":{\"code\":\"rate_limited\",\"message\":\"Too many requests.\"}}", "Retry-After", "7"));
        Kuaa kuaa = client(recorder);
        KuaaException refused = assertThrows(KuaaException.class,
                () -> kuaa.cases().create(CaseRequest.builder().externalReference("x").kind("KYC").build()));
        assertEquals(422, refused.getStatus());
        assertEquals("validation_failed", refused.getCode());
        assertEquals(List.of("must be KYC, KYB or AGE"), refused.getFields().get("kind"));
        KuaaException limited = assertThrows(KuaaException.class, () -> kuaa.cases().get("case_1"));
        assertEquals(429, limited.getStatus());
        assertEquals("rate_limited", limited.getCode());
        assertEquals(7, limited.getRetryAfter());
    }

    @Test
    void aCaptureIsSentAsMultipart() {
        Recorder recorder = new Recorder(request -> json(201, "{\"data\":{\"documents\":[{\"id\":\"doc_1\",\"capture\":\"document\",\"party_id\":\"party_1\","
                + "\"status\":\"received\",\"artifact_id\":null,\"created_at\":\"2027-01-15T08:00:00Z\"}]}}"));
        byte[] front = {(byte) 0xff, (byte) 0xd8, ' ', 'f'};
        Capture got = client(recorder).caseMedia().create("case_1", CaptureForm.builder().kind(CaptureForm.KIND_DOCUMENT).documentType("CNH").side("front")
                .file(List.of(new FilePart("frente.jpg", front, "image/jpeg"), new FilePart("verso.jpg", "verso".getBytes(StandardCharsets.UTF_8), "image/jpeg")))
                .build(), RequestOptions.builder().idempotencyKey("captura-1").build());
        assertEquals("doc_1", got.getDocuments().get(0).getId());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("http://kuaa.test/v1/cases/case_1/media", seen.getUrl());
        assertEquals("captura-1", seen.getHeaders().get("Idempotency-Key"));
        String type = seen.getHeaders().get("Content-Type");
        assertTrue(type.startsWith("multipart/form-data; boundary="), type);
        String boundary = type.substring("multipart/form-data; boundary=".length());
        String body = new String(seen.getBody(), StandardCharsets.ISO_8859_1);
        assertTrue(body.contains("Content-Disposition: form-data; name=\"kind\"\r\n\r\ndocument\r\n"), body);
        assertTrue(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"frente.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nÿØ f\r\n"), body);
        assertTrue(body.contains("filename=\"verso.jpg\""));
        assertFalse(body.contains("name=\"party_id\""));
        assertTrue(body.endsWith("--" + boundary + "--\r\n"));
    }

    @Test
    void aListQueryRepeatsItsName() {
        Recorder recorder = new Recorder(request -> json(200, "{\"data\":{\"case_id\":\"case_1\",\"tags\":[]}}"));
        CaseTagList got = client(recorder).caseTags().delete("case_1", CaseTagsService.DeleteParams.builder().tag(List.of("prioridade", "revisar")).build());
        assertEquals("case_1", got.getCaseId());
        assertEquals("DELETE", recorder.seen.get(0).getMethod());
        assertEquals("http://kuaa.test/v1/cases/case_1/tags?tag=prioridade&tag=revisar", recorder.seen.get(0).getUrl());
    }

    /** The vectors are generated once, in Go, by sdk/generator, and every SDK checks its verification against them. */
    @Test
    @SuppressWarnings("unchecked")
    void theWebhookVectors() throws IOException {
        String text;
        try (InputStream in = KuaaTest.class.getResourceAsStream("/webhook-vectors.json")) {
            assertNotNull(in, "webhook-vectors.json");
            text = new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
        Map<String, Object> vectors = Json.asObject(Json.parse(text));
        assertEquals(WebhookSignature.TOLERANCE_SECONDS, ((Number) vectors.get("tolerance_seconds")).longValue());
        List<Object> all = (List<Object>) vectors.get("vectors");
        assertFalse(all.isEmpty());
        for (Object each : all) {
            Map<String, Object> vector = Json.asObject(each);
            String name = (String) vector.get("name");
            Map<String, Collection<String>> headers = new LinkedHashMap<>();
            for (Map.Entry<String, Object> header : Json.asObject(vector.get("headers")).entrySet()) {
                headers.put(header.getKey(), (List<String>) header.getValue());
            }
            byte[] body = ((String) vector.get("body")).getBytes(StandardCharsets.UTF_8);
            String secret = (String) vector.get("secret");
            long now = ((Number) vector.get("now")).longValue();
            if (!Boolean.TRUE.equals(vector.get("valid"))) {
                assertThrows(WebhookVerificationException.class, () -> WebhookSignature.verify(secret, headers, body, now), name);
                continue;
            }
            WebhookEvent event = WebhookSignature.verify(secret, headers, body, now);
            Map<String, Object> want = Json.asObject(vector.get("event"));
            assertEquals("1.0", event.getSpecversion(), name);
            assertArrayEquals(
                    new Object[] {want.get("id"), want.get("type"), want.get("source"), want.get("subject"), want.get("case_id"), want.get("status"),
                        want.get("environment"), want.get("livemode")},
                    new Object[] {event.getId(), event.getType(), event.getSource(), event.getSubject(), event.getData().getCaseId(),
                        event.getData().getStatus(), event.getData().getEnvironment(), event.getData().getLivemode()},
                    name + ": " + Arrays.toString(new Object[] {event}));
        }
    }
}
