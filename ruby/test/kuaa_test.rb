# frozen_string_literal: true

# KUAA's Ruby SDK tests, with nothing to install: ruby -Ilib -Itest test/kuaa_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "uri"
require "kuaa"

class KuaaTest < Minitest::Test
  # Records each request and answers what the test says.
  class Recorder
    attr_reader :seen

    def initialize(&answer)
      @answer = answer
      @seen = []
    end

    def call(method, url, headers, body, _timeout)
      request = { method: method, url: URI(url), headers: headers, body: body }
      @seen << request
      status, payload, extra = @answer.call(request)
      [status, extra, payload.nil? ? "" : JSON.generate(payload)]
    end
  end

  CASE = {
    "id" => "case_1", "external_reference" => "pedido-1", "kind" => "KYC", "status" => "open", "status_market" => "PROCESSING",
    "livemode" => false, "custom_status" => nil, "current_state" => "collect_identity", "workflow_definition_id" => nil,
    "policy_version_id" => nil, "parent_case_id" => nil, "child_group" => nil,
    "parties" => [{ "id" => "party_1", "kind" => "PERSON", "primary" => true, "identity_id" => nil, "cpf" => "12345678909" }],
    "relationships" => [], "created_at" => "2027-01-15T08:00:00Z", "updated_at" => "2027-01-15T08:00:00Z"
  }.freeze

  def client(&answer)
    recorder = Recorder.new(&answer)
    [Kuaa::Client.new("kuaa_test_abc_secret", base_url: "http://kuaa.test/", transport: recorder), recorder]
  end

  def summary(id)
    { "id" => id, "external_reference" => "ref-#{id}", "kind" => "KYC", "status" => "open", "status_market" => "PROCESSING",
      "livemode" => false, "current_state" => "start", "workflow_definition_id" => nil, "workflow_version_id" => nil,
      "policy_version_id" => nil, "created_at" => "2027-01-15T08:00:00Z", "updated_at" => "2027-01-15T08:00:00Z" }
  end

  def query(request)
    URI.decode_www_form(request[:url].query.to_s).to_h
  end

  def test_a_call_carries_the_key_and_unwraps_the_data
    kuaa, recorder = client { [200, { "data" => CASE }, { "kuaa-livemode" => "false", "kuaa-environment" => "sandbox", "x-request-id" => "req_1" }] }
    got = kuaa.cases.get("case_1")
    assert_equal ["case_1", "open", "12345678909"], [got.id, got.status, got.parties.first.cpf]
    seen = recorder.seen.first
    assert_equal ["GET", "/v1/cases/case_1"], [seen[:method], seen[:url].path]
    assert_equal "Bearer kuaa_test_abc_secret", seen[:headers]["Authorization"]
    last = kuaa.last_response
    assert_equal [200, false, "sandbox", false, "req_1"], [last.status, last.livemode, last.environment, last.idempotent_replayed, last.request_id]
  end

  def test_a_write_sends_its_body_and_idempotency_key
    kuaa, recorder = client { [200, { "data" => CASE, "meta" => { "created" => false } }, { "idempotent-replayed" => "true" }] }
    got = kuaa.cases.create(Kuaa::CaseRequest.new(external_reference: "pedido-1", kind: "KYC"), idempotency_key: "pedido-1")
    assert_equal "pedido-1", got.external_reference
    seen = recorder.seen.first
    assert_equal ["POST", "/v1/cases", "pedido-1", "application/json"],
                 [seen[:method], seen[:url].path, seen[:headers]["Idempotency-Key"], seen[:headers]["Content-Type"]]
    assert_equal({ "external_reference" => "pedido-1", "kind" => "KYC" }, JSON.parse(seen[:body]))
    assert kuaa.last_response.idempotent_replayed
  end

  def test_iterating_walks_every_page_by_cursor
    following = { "" => "c2", "c2" => "c3", "c3" => nil }
    ids = { "" => "case_1", "c2" => "case_2", "c3" => "case_3" }
    kuaa, recorder = client do |request|
      values = query(request)
      assert_equal %w[1 open], [values["limit"], values["status"]]
      cursor = values["cursor"].to_s
      meta = { "next_cursor" => following[cursor], "has_more" => !following[cursor].nil?, "limit" => 1 }
      [200, { "data" => { "livemode" => false, "cases" => [summary(ids[cursor])] }, "meta" => meta }, {}]
    end
    assert_equal %w[case_1 case_2 case_3], kuaa.cases.list_iter(limit: 1, status: "open").map(&:id)
    assert_equal 3, recorder.seen.length
  end

  def test_a_refusal_is_a_typed_error
    kuaa, = client do |request|
      if request[:url].path == "/v1/cases"
        problem = { "code" => "validation_failed", "message" => "The input has invalid fields.", "fields" => { "kind" => ["must be KYC, KYB or AGE"] } }
        [422, { "error" => problem }, {}]
      else
        [429, { "error" => { "code" => "rate_limited", "message" => "Too many requests." } }, { "retry-after" => "7" }]
      end
    end
    refused = assert_raises(Kuaa::Error) { kuaa.cases.create({ external_reference: "x", kind: "KYC" }) }
    assert_equal [422, "validation_failed"], [refused.status, refused.code]
    assert_equal ["must be KYC, KYB or AGE"], refused.fields["kind"]
    limited = assert_raises(Kuaa::Error) { kuaa.cases.get("case_1") }
    assert_equal [429, "rate_limited", 7], [limited.status, limited.code, limited.retry_after]
  end

  def test_a_capture_is_sent_as_multipart
    document = { "id" => "doc_1", "capture" => "document", "party_id" => "party_1", "status" => "received", "artifact_id" => nil,
                 "created_at" => "2027-01-15T08:00:00Z" }
    kuaa, recorder = client { [201, { "data" => { "documents" => [document] } }, {}] }
    files = [Kuaa::FilePart.new("frente.jpg", "\xFF\xD8 frente".b, "image/jpeg"), Kuaa::FilePart.new("verso.jpg", "verso", "image/jpeg")]
    got = kuaa.case_media.create("case_1", { kind: "document", document_type: "CNH", side: "front", file: files }, idempotency_key: "captura-1")
    assert_equal "doc_1", got.documents.first.id
    seen = recorder.seen.first
    assert_equal ["/v1/cases/case_1/media", "captura-1"], [seen[:url].path, seen[:headers]["Idempotency-Key"]]
    type = seen[:headers]["Content-Type"]
    assert type.start_with?("multipart/form-data; boundary=")
    boundary = type.delete_prefix("multipart/form-data; boundary=")
    body = seen[:body]
    assert_includes body, "Content-Disposition: form-data; name=\"kind\"\r\n\r\ndocument\r\n".b
    assert_includes body, "Content-Disposition: form-data; name=\"file\"; filename=\"frente.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n\xFF\xD8 frente\r\n".b
    assert_includes body, "filename=\"verso.jpg\"".b
    refute_includes body, "name=\"party_id\"".b
    assert body.end_with?("--#{boundary}--\r\n".b)
  end

  def test_a_list_query_repeats_its_name
    kuaa, recorder = client { [200, { "data" => { "case_id" => "case_1", "tags" => [] } }, {}] }
    got = kuaa.case_tags.delete("case_1", tag: %w[prioridade revisar])
    assert_equal "case_1", got.case_id
    assert_equal ["DELETE", "tag=prioridade&tag=revisar"], [recorder.seen.first[:method], recorder.seen.first[:url].query]
  end

  # The vectors are generated once, in Go, by sdk/generator, and every SDK
  # checks its verification against them.
  def test_the_webhook_vectors
    vectors = JSON.parse(File.read(File.join(__dir__, "webhook-vectors.json"), encoding: "UTF-8"))
    assert_equal Kuaa::WEBHOOK_TOLERANCE_SECONDS, vectors["tolerance_seconds"]
    refute_empty vectors["vectors"]
    vectors["vectors"].each do |vector|
      verify = -> { Kuaa.verify_webhook(vector["secret"], vector["headers"], vector["body"], now: Time.at(vector["now"])) }
      unless vector["valid"]
        assert_raises(Kuaa::WebhookVerificationError, vector["name"]) { verify.call }
        next
      end
      event = verify.call
      want = vector["event"]
      assert_equal "1.0", event.specversion, vector["name"]
      assert_equal want.values_at("id", "type", "source", "subject", "case_id", "status", "environment", "livemode"),
                   [event.id, event.type, event.source, event.subject, event.data.case_id, event.data.status, event.data.environment, event.data.livemode],
                   vector["name"]
    end
  end

  def test_the_real_http_sends_and_reads_through_net_http
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new { loop { answer(server.accept) } }
    base_url = "http://127.0.0.1:#{server.addr[1]}"
    kuaa = Kuaa::Client.new("kuaa_test_abc_secret", base_url: base_url)
    tags = kuaa.case_tags.create("case 1/2", { tags: ["prioridade"] }, idempotency_key: "tag-1")
    assert_equal ["prioridade", "tag-1", "POST /v1/cases/case%201%2F2/tags application/json"], [tags.tags.first.name, tags.tags.first.slug, tags.tags.first.created_at]
    assert_equal [false, "sandbox"], [kuaa.last_response.livemode, kuaa.last_response.environment]
    refused = assert_raises(Kuaa::Error) { Kuaa::Client.new("kuaa_test_other", base_url: base_url).cases.get("case_1") }
    assert_equal [401, "unauthenticated", 3, "req_401"], [refused.status, refused.code, refused.retry_after, refused.request_id]
  ensure
    thread&.kill
    server&.close
  end

  private

  # Answers one connection as the API would: what it was sent, as a case's
  # tags, or a 401 to another key.
  def answer(socket)
    request_line = socket.gets.to_s
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(headers["content-length"].to_i).to_s.force_encoding(Encoding::UTF_8)
    status, extra, payload = respond(request_line.split[0, 2].join(" "), headers, body)
    encoded = JSON.generate(payload).b
    socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n#{extra}Content-Length: #{encoded.bytesize}\r\nConnection: close\r\n\r\n")
    socket.write(encoded)
  ensure
    socket.close
  end

  def respond(request, headers, body)
    if headers["authorization"] != "Bearer kuaa_test_abc_secret"
      return [401, "Retry-After: 3\r\nX-Request-ID: req_401\r\n", { "error" => { "code" => "unauthenticated", "message" => "Send a key." } }]
    end

    tags = JSON.parse(body)["tags"].map do |name|
      { "id" => "tag_#{name}", "name" => name, "slug" => headers["idempotency-key"].to_s, "created_at" => "#{request} #{headers["content-type"]}" }
    end
    [200, "Kuaa-Livemode: false\r\nKuaa-Environment: sandbox\r\n", { "data" => { "case_id" => "case_1", "tags" => tags } }]
  end
end
