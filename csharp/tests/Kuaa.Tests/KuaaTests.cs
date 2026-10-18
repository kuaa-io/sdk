using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Kuaa.Tests;

public class KuaaTests
{
    private sealed record Seen(HttpMethod Method, Uri Url, Dictionary<string, string> Headers, byte[]? Body);

    private sealed record Answer(HttpStatusCode Status, string? Json, Dictionary<string, string>? Headers = null);

    /// <summary>Answers every request with what answer says, recording what was sent.</summary>
    private sealed class Recorder(Func<Seen, Answer> answer) : HttpMessageHandler
    {
        public List<Seen> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var headers = request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase);
            byte[]? body = null;
            if (request.Content is not null)
            {
                foreach (var header in request.Content.Headers)
                {
                    headers[header.Key] = string.Join(",", header.Value);
                }
                body = await request.Content.ReadAsByteArrayAsync(cancellationToken);
            }
            var seen = new Seen(request.Method, request.RequestUri!, headers, body);
            Requests.Add(seen);
            var reply = answer(seen);
            var response = new HttpResponseMessage(reply.Status) { Content = new StringContent(reply.Json ?? "", Encoding.UTF8, "application/json") };
            foreach (var (name, value) in reply.Headers ?? [])
            {
                response.Headers.TryAddWithoutValidation(name, value);
            }
            return response;
        }
    }

    private const string CaseJson = """{"id":"case_1","external_reference":"pedido-1","kind":"KYC","status":"open","status_market":"PROCESSING","livemode":false,"custom_status":null,"current_state":"collect_identity","workflow_definition_id":null,"policy_version_id":null,"parent_case_id":null,"child_group":null,"parties":[{"id":"party_1","kind":"PERSON","primary":true,"identity_id":null,"cpf":"12345678909"}],"relationships":[],"created_at":"2027-01-15T08:00:00Z","updated_at":"2027-01-15T08:00:00Z"}""";

    private static string Summary(string id) =>
        $$"""{"id":"{{id}}","external_reference":"ref-{{id}}","kind":"KYC","status":"open","status_market":"PROCESSING","livemode":false,"current_state":"start","workflow_definition_id":null,"workflow_version_id":null,"policy_version_id":null,"created_at":"2027-01-15T08:00:00Z","updated_at":"2027-01-15T08:00:00Z"}""";

    private static KuaaClient Client(Recorder recorder) =>
        new("kuaa_test_abc_secret", new KuaaClientOptions { BaseUrl = "http://kuaa.test/", Handler = recorder });

    private static Dictionary<string, string> Query(Uri url) =>
        url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(pair => pair.Split('=', 2))
            .ToDictionary(parts => parts[0], parts => parts.Length > 1 ? Uri.UnescapeDataString(parts[1]) : "");

    [Fact]
    public async Task ACallCarriesTheKeyAndUnwrapsTheData()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, "{\"data\":" + CaseJson + "}",
            new() { ["Kuaa-Livemode"] = "false", ["Kuaa-Environment"] = "sandbox", ["X-Request-ID"] = "req_1" }));
        var kuaa = Client(recorder);
        var got = await kuaa.Cases.GetAsync("case_1");
        Assert.Equal("case_1", got.Id);
        Assert.Equal(Case.StatusOpen, got.Status);
        Assert.Equal("12345678909", got.Parties[0].Cpf);
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Get, seen.Method);
        Assert.Equal("/v1/cases/case_1", seen.Url.AbsolutePath);
        Assert.Equal("Bearer kuaa_test_abc_secret", seen.Headers["Authorization"]);
        Assert.Equal("kuaa-csharp/" + KuaaClient.Version, seen.Headers["User-Agent"]);
        Assert.Equal(new ResponseInfo(200, false, "sandbox", false, "req_1"), kuaa.LastResponse);
    }

    [Fact]
    public async Task AWriteSendsItsBodyAndIdempotencyKey()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, "{\"data\":" + CaseJson + ",\"meta\":{\"created\":false}}",
            new() { ["Idempotent-Replayed"] = "true" }));
        var kuaa = Client(recorder);
        var got = await kuaa.Cases.CreateAsync(new CaseRequest { ExternalReference = "pedido-1", Kind = CaseRequest.KindKYC }, new RequestOptions { IdempotencyKey = "pedido-1" });
        Assert.Equal("pedido-1", got.ExternalReference);
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Post, seen.Method);
        Assert.Equal("/v1/cases", seen.Url.AbsolutePath);
        Assert.Equal("pedido-1", seen.Headers["Idempotency-Key"]);
        Assert.Equal("application/json", seen.Headers["Content-Type"]);
        Assert.Equal("""{"external_reference":"pedido-1","kind":"KYC"}""", Encoding.UTF8.GetString(seen.Body!));
        Assert.True(kuaa.LastResponse!.IdempotentReplayed);
    }

    [Fact]
    public async Task ANestedBodyIsWrittenWhole()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.Created, "{\"data\":" + CaseJson + "}"));
        await Client(recorder).Cases.CreateAsync(new CaseRequest
        {
            ExternalReference = "pedido-1",
            Kind = "KYC",
            Parties = [new CaseRequestParty { Kind = "PERSON", Primary = true, Cpf = "123.456.789-09" }],
        });
        Assert.Equal("""{"external_reference":"pedido-1","kind":"KYC","parties":[{"cpf":"123.456.789-09","kind":"PERSON","primary":true}]}""",
            Encoding.UTF8.GetString(recorder.Requests[0].Body!));
    }

    [Fact]
    public async Task IteratingWalksEveryPageByCursor()
    {
        var following = new Dictionary<string, string?> { [""] = "c2", ["c2"] = "c3", ["c3"] = null };
        var ids = new Dictionary<string, string> { [""] = "case_1", ["c2"] = "case_2", ["c3"] = "case_3" };
        var recorder = new Recorder(seen =>
        {
            var query = Query(seen.Url);
            Assert.Equal("1", query["limit"]);
            Assert.Equal("open", query["status"]);
            var cursor = query.GetValueOrDefault("cursor", "");
            var next = following[cursor];
            var meta = next is null ? """{"next_cursor":null,"has_more":false,"limit":1}""" : $$"""{"next_cursor":"{{next}}","has_more":true,"limit":1}""";
            return new Answer(HttpStatusCode.OK, "{\"data\":{\"livemode\":false,\"cases\":[" + Summary(ids[cursor]) + "]},\"meta\":" + meta + "}");
        });
        var walked = new List<string>();
        await foreach (var each in Client(recorder).Cases.ListIterAsync(new CasesListParams { Limit = 1, Status = "open" }))
        {
            walked.Add(each.Id);
        }
        Assert.Equal(["case_1", "case_2", "case_3"], walked);
        Assert.Equal(3, recorder.Requests.Count);
    }

    [Fact]
    public async Task ARefusalIsATypedError()
    {
        var recorder = new Recorder(seen => seen.Url.AbsolutePath == "/v1/cases"
            ? new Answer(HttpStatusCode.UnprocessableEntity, """{"error":{"code":"validation_failed","message":"The input has invalid fields.","fields":{"kind":["must be KYC, KYB or AGE"]}}}""")
            : new Answer(HttpStatusCode.TooManyRequests, """{"error":{"code":"rate_limited","message":"Too many requests."}}""", new() { ["Retry-After"] = "7" }));
        var kuaa = Client(recorder);
        var refused = await Assert.ThrowsAsync<KuaaException>(() => kuaa.Cases.CreateAsync(new CaseRequest { ExternalReference = "x", Kind = "KYC" }));
        Assert.Equal(422, refused.Status);
        Assert.Equal("validation_failed", refused.Code);
        Assert.Equal(["must be KYC, KYB or AGE"], refused.Fields["kind"]);
        var limited = await Assert.ThrowsAsync<KuaaException>(() => kuaa.Cases.GetAsync("case_1"));
        Assert.Equal(429, limited.Status);
        Assert.Equal("rate_limited", limited.Code);
        Assert.Equal(7, limited.RetryAfter);
    }

    [Fact]
    public async Task ACaptureIsSentAsMultipart()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.Created,
            """{"data":{"documents":[{"id":"doc_1","capture":"document","party_id":"party_1","status":"received","artifact_id":null,"created_at":"2027-01-15T08:00:00Z"}]}}"""));
        byte[] front = [0xff, 0xd8, (byte)' ', (byte)'f'];
        var got = await Client(recorder).CaseMedia.CreateAsync("case_1", new CaptureForm
        {
            Kind = CaptureForm.KindDocument,
            DocumentType = "CNH",
            Side = "front",
            File = [new FilePart("frente.jpg", front, "image/jpeg"), new FilePart("verso.jpg", Encoding.UTF8.GetBytes("verso"), "image/jpeg")],
        }, new RequestOptions { IdempotencyKey = "captura-1" });
        Assert.Equal("doc_1", got.Documents[0].Id);
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal("/v1/cases/case_1/media", seen.Url.AbsolutePath);
        Assert.Equal("captura-1", seen.Headers["Idempotency-Key"]);
        var type = seen.Headers["Content-Type"];
        Assert.StartsWith("multipart/form-data; boundary=", type, StringComparison.Ordinal);
        var boundary = type["multipart/form-data; boundary=".Length..];
        var body = Encoding.Latin1.GetString(seen.Body!);
        Assert.Contains("Content-Disposition: form-data; name=\"kind\"\r\n\r\ndocument\r\n", body, StringComparison.Ordinal);
        Assert.Contains("Content-Disposition: form-data; name=\"file\"; filename=\"frente.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nÿØ f\r\n", body, StringComparison.Ordinal);
        Assert.Contains("filename=\"verso.jpg\"", body, StringComparison.Ordinal);
        Assert.DoesNotContain("name=\"party_id\"", body, StringComparison.Ordinal);
        Assert.EndsWith("--" + boundary + "--\r\n", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AListQueryRepeatsItsName()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"data":{"case_id":"case_1","tags":[]}}"""));
        var got = await Client(recorder).CaseTags.DeleteAsync("case_1", new CaseTagsDeleteParams { Tag = ["prioridade", "revisar"] });
        Assert.Equal("case_1", got.CaseId);
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Delete, seen.Method);
        Assert.Equal("?tag=prioridade&tag=revisar", seen.Url.Query);
    }

    /// <summary>The vectors are generated once, in Go, by sdk/generator, and every SDK checks its verification against them.</summary>
    [Fact]
    public void TheWebhookVectors()
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "webhook-vectors.json")));
        var root = document.RootElement;
        Assert.Equal((long)WebhookSignature.Tolerance.TotalSeconds, root.GetProperty("tolerance_seconds").GetInt64());
        var vectors = root.GetProperty("vectors").EnumerateArray().ToList();
        Assert.NotEmpty(vectors);
        foreach (var vector in vectors)
        {
            var name = vector.GetProperty("name").GetString()!;
            var headers = vector.GetProperty("headers").EnumerateObject()
                .Select(header => new KeyValuePair<string, IEnumerable<string>>(header.Name, header.Value.EnumerateArray().Select(line => line.GetString()!).ToList()))
                .ToList();
            var body = Encoding.UTF8.GetBytes(vector.GetProperty("body").GetString()!);
            var secret = vector.GetProperty("secret").GetString()!;
            var now = DateTimeOffset.FromUnixTimeSeconds(vector.GetProperty("now").GetInt64());
            if (!vector.GetProperty("valid").GetBoolean())
            {
                Assert.Throws<WebhookVerificationException>(() => WebhookSignature.Verify(secret, headers, body, now));
                continue;
            }
            var webhook = WebhookSignature.Verify(secret, headers, body, now);
            var want = vector.GetProperty("event");
            Assert.True(webhook.Specversion == "1.0", name);
            Assert.Equal(
                (want.GetProperty("id").GetString(), want.GetProperty("type").GetString(), want.GetProperty("source").GetString(), want.GetProperty("subject").GetString(),
                    want.GetProperty("case_id").GetString(), want.GetProperty("status").GetString(), want.GetProperty("environment").GetString(), want.GetProperty("livemode").GetBoolean()),
                (webhook.Id, webhook.Type, webhook.Source, webhook.Subject, webhook.Data.CaseId, webhook.Data.Status, webhook.Data.Environment, webhook.Data.Livemode));
        }
    }
}
