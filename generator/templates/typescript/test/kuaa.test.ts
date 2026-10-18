import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { Kuaa, KuaaError, verifyWebhook, WEBHOOK_TOLERANCE_SECONDS, WebhookVerificationError } from "../src/index.ts";

interface Seen {
  method: string;
  url: URL;
  headers: Headers;
  body: unknown;
}

function client(answer: (seen: Seen) => Response): { kuaa: Kuaa; seen: Seen[] } {
  const seen: Seen[] = [];
  const fake: typeof fetch = async (input, init) => {
    const request = { method: init?.method ?? "GET", url: new URL(String(input)), headers: new Headers(init?.headers), body: init?.body };
    seen.push(request);
    return answer(request);
  };
  return { kuaa: new Kuaa({ apiKey: "kuaa_test_abc_secret", baseUrl: "http://kuaa.test/", fetch: fake }), seen };
}

const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

const kase = {
  id: "case_1", external_reference: "pedido-1", kind: "KYC", status: "open", status_market: "PROCESSING", livemode: false,
  custom_status: null, current_state: "collect_identity", workflow_definition_id: null, policy_version_id: null,
  parent_case_id: null, child_group: null, parties: [{ id: "party_1", kind: "PERSON", primary: true, identity_id: null, cpf: "12345678909" }],
  relationships: [], created_at: "2027-01-15T08:00:00Z", updated_at: "2027-01-15T08:00:00Z",
};

const summary = (id: string) => ({
  id, external_reference: `ref-${id}`, kind: "KYC", status: "open", status_market: "PROCESSING", livemode: false, current_state: "start",
  workflow_definition_id: null, workflow_version_id: null, policy_version_id: null, created_at: "2027-01-15T08:00:00Z", updated_at: "2027-01-15T08:00:00Z",
});

test("a call carries the key and unwraps the data", async () => {
  const { kuaa, seen } = client(() => json(200, { data: kase }, { "Kuaa-Livemode": "false", "Kuaa-Environment": "sandbox", "X-Request-ID": "req_1" }));
  const got = await kuaa.cases.get("case_1");
  assert.equal(got.id, "case_1");
  assert.equal(got.status, "open");
  assert.equal(got.parties[0]?.cpf, "12345678909");
  assert.equal(seen[0]?.method, "GET");
  assert.equal(seen[0]?.url.pathname, "/v1/cases/case_1");
  assert.equal(seen[0]?.headers.get("authorization"), "Bearer kuaa_test_abc_secret");
  assert.deepEqual(kuaa.lastResponse, { status: 200, livemode: false, environment: "sandbox", idempotentReplayed: false, requestId: "req_1" });
});

test("a write sends its body and idempotency key", async () => {
  const { kuaa, seen } = client(() => json(200, { data: kase, meta: { created: false } }, { "Idempotent-Replayed": "true" }));
  const got = await kuaa.cases.create({ external_reference: "pedido-1", kind: "KYC" }, { idempotencyKey: "pedido-1" });
  assert.equal(got.external_reference, "pedido-1");
  assert.equal(seen[0]?.method, "POST");
  assert.equal(seen[0]?.url.pathname, "/v1/cases");
  assert.equal(seen[0]?.headers.get("idempotency-key"), "pedido-1");
  assert.equal(seen[0]?.headers.get("content-type"), "application/json");
  assert.deepEqual(JSON.parse(String(seen[0]?.body)), { external_reference: "pedido-1", kind: "KYC" });
  assert.equal(kuaa.lastResponse?.idempotentReplayed, true);
});

test("iterating walks every page by cursor", async () => {
  const next: Record<string, string | null> = { "": "c2", c2: "c3", c3: null };
  const ids: Record<string, string> = { "": "case_1", c2: "case_2", c3: "case_3" };
  const { kuaa, seen } = client(({ url }) => {
    const cursor = url.searchParams.get("cursor") ?? "";
    return json(200, { data: { livemode: false, cases: [summary(ids[cursor] ?? "?")] }, meta: { next_cursor: next[cursor], has_more: next[cursor] !== null, limit: 1 } });
  });
  const walked: string[] = [];
  for await (const item of kuaa.cases.listIter({ limit: 1, status: "open" })) {
    walked.push(item.id);
  }
  assert.deepEqual(walked, ["case_1", "case_2", "case_3"]);
  assert.equal(seen.length, 3);
  for (const each of seen) {
    assert.equal(each.url.searchParams.get("limit"), "1");
    assert.equal(each.url.searchParams.get("status"), "open");
  }
});

test("a refusal is a typed error", async () => {
  const { kuaa } = client(({ url }) =>
    url.pathname === "/v1/cases"
      ? json(422, { error: { code: "validation_failed", message: "The input has invalid fields.", fields: { kind: ["must be KYC, KYB or AGE"] } } })
      : json(429, { error: { code: "rate_limited", message: "Too many requests." } }, { "Retry-After": "7" }),
  );
  await assert.rejects(kuaa.cases.create({ external_reference: "x", kind: "KYC" }), (error: unknown) => {
    assert.ok(error instanceof KuaaError);
    assert.equal(error.status, 422);
    assert.equal(error.code, "validation_failed");
    assert.deepEqual(error.fields["kind"], ["must be KYC, KYB or AGE"]);
    return true;
  });
  await assert.rejects(kuaa.cases.get("case_1"), (error: unknown) => {
    assert.ok(error instanceof KuaaError);
    assert.equal(error.status, 429);
    assert.equal(error.code, "rate_limited");
    assert.equal(error.retryAfter, 7);
    return true;
  });
});

test("a capture is sent as multipart", async () => {
  const { kuaa, seen } = client(() =>
    json(201, { data: { documents: [{ id: "doc_1", capture: "document", party_id: "party_1", status: "received", artifact_id: null, created_at: "2027-01-15T08:00:00Z" }] } }),
  );
  const got = await kuaa.caseMedia.create(
    "case_1",
    {
      kind: "document",
      document_type: "CNH",
      side: "front",
      file: [
        { filename: "frente.jpg", contentType: "image/jpeg", data: new Uint8Array([0xff, 0xd8, 0x20, 0x66]) },
        { filename: "verso.jpg", contentType: "image/jpeg", data: new TextEncoder().encode("verso") },
      ],
    },
    { idempotencyKey: "captura-1" },
  );
  assert.equal(got.documents[0]?.id, "doc_1");
  const form = seen[0]?.body;
  assert.ok(form instanceof FormData);
  assert.equal(seen[0]?.url.pathname, "/v1/cases/case_1/media");
  assert.equal(seen[0]?.headers.get("idempotency-key"), "captura-1");
  assert.equal(seen[0]?.headers.get("content-type"), null);
  assert.equal(form.get("kind"), "document");
  assert.equal(form.get("side"), "front");
  assert.equal(form.get("party_id"), null);
  const files = form.getAll("file") as File[];
  assert.equal(files.length, 2);
  assert.equal(files[0]?.name, "frente.jpg");
  assert.equal(files[0]?.type, "image/jpeg");
  assert.deepEqual(new Uint8Array(await files[0]!.arrayBuffer()), new Uint8Array([0xff, 0xd8, 0x20, 0x66]));
});

test("a list query repeats its name", async () => {
  const { kuaa, seen } = client(() => json(200, { data: { case_id: "case_1", tags: [] } }));
  const got = await kuaa.caseTags.delete("case_1", { tag: ["prioridade", "revisar"] });
  assert.equal(got.case_id, "case_1");
  assert.equal(seen[0]?.method, "DELETE");
  assert.equal(seen[0]?.url.search, "?tag=prioridade&tag=revisar");
});

interface Vector {
  name: string;
  secret: string;
  now: number;
  headers: Record<string, string[]>;
  body: string;
  valid: boolean;
  event?: { id: string; type: string; source: string; subject: string; case_id: string; status: string; environment: string; livemode: boolean };
}

// The vectors are generated once, in Go, by sdk/generator, and every SDK
// checks its verification against them.
test("the webhook vectors", async () => {
  const vectors = JSON.parse(readFileSync(new URL("./webhook-vectors.json", import.meta.url), "utf8")) as { tolerance_seconds: number; vectors: Vector[] };
  assert.equal(vectors.tolerance_seconds, WEBHOOK_TOLERANCE_SECONDS);
  assert.ok(vectors.vectors.length > 0);
  for (const vector of vectors.vectors) {
    const verify = verifyWebhook(vector.secret, vector.headers, vector.body, vector.now * 1000);
    if (!vector.valid) {
      await assert.rejects(verify, WebhookVerificationError, vector.name);
      continue;
    }
    const event = await verify;
    const want = vector.event!;
    assert.equal(event.specversion, "1.0", vector.name);
    assert.deepEqual(
      [event.id, event.type, event.source, event.subject, event.data.case_id, event.data.status, event.data.environment, event.data.livemode],
      [want.id, want.type, want.source, want.subject, want.case_id, want.status, want.environment, want.livemode],
      vector.name,
    );
    // fetch's Headers joins repeated lines with commas, which verifies the same.
    const fetched = new Headers();
    for (const [name, lines] of Object.entries(vector.headers)) {
      for (const line of lines) {
        fetched.append(name, line);
      }
    }
    assert.equal((await verifyWebhook(vector.secret, fetched, new TextEncoder().encode(vector.body), vector.now * 1000)).id, want.id, vector.name);
  }
});
