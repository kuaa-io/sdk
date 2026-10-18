# KUAA's Elixir SDK tests, with nothing to install: mix test

defmodule KuaaTest do
  use ExUnit.Case, async: true

  @case %{
    "id" => "case_1",
    "external_reference" => "pedido-1",
    "kind" => "KYC",
    "status" => "open",
    "status_market" => "PROCESSING",
    "livemode" => false,
    "custom_status" => nil,
    "current_state" => "collect_identity",
    "workflow_definition_id" => nil,
    "policy_version_id" => nil,
    "parent_case_id" => nil,
    "child_group" => nil,
    "parties" => [
      %{
        "id" => "party_1",
        "kind" => "PERSON",
        "primary" => true,
        "identity_id" => nil,
        "cpf" => "12345678909"
      }
    ],
    "relationships" => [],
    "created_at" => "2027-01-15T08:00:00Z",
    "updated_at" => "2027-01-15T08:00:00Z"
  }

  # A client whose transport sends each request to the test and answers what
  # `answer` says.
  defp client(answer) do
    test = self()

    transport = fn method, url, headers, body, _timeout ->
      request = %{method: method, url: URI.parse(url), headers: Map.new(headers), body: body}
      send(test, {:request, request})
      {status, payload, extra} = answer.(request)
      {:ok, {status, extra, if(payload, do: JSON.encode!(payload), else: "")}}
    end

    Kuaa.new("kuaa_test_abc_secret", base_url: "http://kuaa.test/", transport: transport)
  end

  defp summary(id) do
    %{
      "id" => id,
      "external_reference" => "ref-#{id}",
      "kind" => "KYC",
      "status" => "open",
      "status_market" => "PROCESSING",
      "livemode" => false,
      "current_state" => "start",
      "workflow_definition_id" => nil,
      "workflow_version_id" => nil,
      "policy_version_id" => nil,
      "created_at" => "2027-01-15T08:00:00Z",
      "updated_at" => "2027-01-15T08:00:00Z"
    }
  end

  defp query(request), do: URI.decode_query(request.url.query || "")

  test "a call carries the key and unwraps the data" do
    kuaa =
      client(fn _request ->
        {200, %{"data" => @case},
         [
           {"kuaa-livemode", "false"},
           {"kuaa-environment", "sandbox"},
           {"x-request-id", "req_1"}
         ]}
      end)

    assert {:ok, %Kuaa.Case{id: "case_1", status: "open", parties: [party]}} =
             Kuaa.Cases.get(kuaa, "case_1")

    assert party.cpf == "12345678909"
    assert_received {:request, seen}
    assert {seen.method, seen.url.path} == {"GET", "/v1/cases/case_1"}
    assert seen.headers["Authorization"] == "Bearer kuaa_test_abc_secret"

    assert %Kuaa.ResponseInfo{
             status: 200,
             livemode: false,
             environment: "sandbox",
             idempotent_replayed: false,
             request_id: "req_1"
           } = Kuaa.last_response()
  end

  test "a write sends its body and idempotency key" do
    kuaa =
      client(fn _request ->
        {200, %{"data" => @case, "meta" => %{"created" => false}},
         [{"idempotent-replayed", "true"}]}
      end)

    assert {:ok, %Kuaa.Case{external_reference: "pedido-1"}} =
             Kuaa.Cases.create(kuaa, %Kuaa.CaseRequest{external_reference: "pedido-1", kind: "KYC"},
               idempotency_key: "pedido-1"
             )

    assert_received {:request, seen}
    assert {seen.method, seen.url.path} == {"POST", "/v1/cases"}
    assert seen.headers["Idempotency-Key"] == "pedido-1"
    assert seen.headers["Content-Type"] == "application/json"
    assert JSON.decode!(seen.body) == %{"external_reference" => "pedido-1", "kind" => "KYC"}
    assert Kuaa.last_response().idempotent_replayed
  end

  test "iterating walks every page by cursor" do
    following = %{"" => "c2", "c2" => "c3", "c3" => nil}
    ids = %{"" => "case_1", "c2" => "case_2", "c3" => "case_3"}

    kuaa =
      client(fn request ->
        values = query(request)
        cursor = values["cursor"] || ""
        meta = %{"next_cursor" => following[cursor], "has_more" => following[cursor] != nil}
        data = %{"livemode" => false, "cases" => [summary(ids[cursor])]}
        send(self(), {:query, values["limit"], values["status"]})
        {200, %{"data" => data, "meta" => meta}, []}
      end)

    walked = kuaa |> Kuaa.Cases.list_stream(limit: 1, status: "open") |> Enum.map(& &1.id)
    assert walked == ["case_1", "case_2", "case_3"]

    for _page <- 1..3 do
      assert_received {:query, "1", "open"}
    end
  end

  test "a refusal is a typed error" do
    kuaa =
      client(fn
        %{url: %URI{path: "/v1/cases"}} ->
          problem = %{
            "code" => "validation_failed",
            "message" => "The input has invalid fields.",
            "fields" => %{"kind" => ["must be KYC, KYB or AGE"]}
          }

          {422, %{"error" => problem}, []}

        _request ->
          {429, %{"error" => %{"code" => "rate_limited", "message" => "Too many requests."}},
           [{"retry-after", "7"}]}
      end)

    assert {:error, %Kuaa.Error{status: 422, code: "validation_failed", fields: fields}} =
             Kuaa.Cases.create(kuaa, external_reference: "x", kind: "KYC")

    assert fields["kind"] == ["must be KYC, KYB or AGE"]

    assert {:error, %Kuaa.Error{status: 429, code: "rate_limited", retry_after: 7}} =
             Kuaa.Cases.get(kuaa, "case_1")
  end

  test "a capture is sent as multipart" do
    document = %{
      "id" => "doc_1",
      "capture" => "document",
      "party_id" => "party_1",
      "status" => "received",
      "artifact_id" => nil,
      "created_at" => "2027-01-15T08:00:00Z"
    }

    kuaa = client(fn _request -> {201, %{"data" => %{"documents" => [document]}}, []} end)

    files = [
      %Kuaa.FilePart{filename: "frente.jpg", data: <<0xFF, 0xD8, " frente">>, content_type: "image/jpeg"},
      %Kuaa.FilePart{filename: "verso.jpg", data: "verso", content_type: "image/jpeg"}
    ]

    assert {:ok, %Kuaa.Capture{documents: [%Kuaa.CaptureDocument{id: "doc_1"}]}} =
             Kuaa.CaseMedia.create(
               kuaa,
               "case_1",
               [kind: "document", document_type: "CNH", side: "front", file: files],
               idempotency_key: "captura-1"
             )

    assert_received {:request, seen}
    assert {seen.url.path, seen.headers["Idempotency-Key"]} == {"/v1/cases/case_1/media", "captura-1"}
    "multipart/form-data; boundary=" <> boundary = seen.headers["Content-Type"]
    assert seen.body =~ "Content-Disposition: form-data; name=\"kind\"\r\n\r\ndocument\r\n"

    assert String.contains?(
             seen.body,
             "Content-Disposition: form-data; name=\"file\"; filename=\"frente.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n" <>
               <<0xFF, 0xD8, " frente\r\n">>
           )

    assert seen.body =~ "filename=\"verso.jpg\""
    refute seen.body =~ "name=\"party_id\""
    assert String.ends_with?(seen.body, "--" <> boundary <> "--\r\n")
  end

  test "a list query repeats its name" do
    kuaa = client(fn _request -> {200, %{"data" => %{"case_id" => "case_1", "tags" => []}}, []} end)

    assert {:ok, %Kuaa.CaseTagList{case_id: "case_1"}} =
             Kuaa.CaseTags.delete(kuaa, "case_1", tag: ["prioridade", "revisar"])

    assert_received {:request, seen}
    assert {seen.method, seen.url.query} == {"DELETE", "tag=prioridade&tag=revisar"}
  end

  # The vectors are generated once, in Go, by sdk/generator, and every SDK
  # checks its verification against them.
  test "the webhook vectors" do
    vectors = Path.join(__DIR__, "webhook-vectors.json") |> File.read!() |> JSON.decode!()
    assert vectors["tolerance_seconds"] == Kuaa.WebhookSignature.tolerance_seconds()
    assert vectors["vectors"] != []

    for vector <- vectors["vectors"] do
      result = Kuaa.verify_webhook(vector["secret"], vector["headers"], vector["body"], now: vector["now"])

      if vector["valid"] do
        assert {:ok, event} = result, vector["name"]
        want = vector["event"]
        assert event.specversion == "1.0"

        assert [event.id, event.type, event.source, event.subject] ==
                 [want["id"], want["type"], want["source"], want["subject"]],
               vector["name"]

        assert [event.data.case_id, event.data.status, event.data.environment, event.data.livemode] ==
                 [want["case_id"], want["status"], want["environment"], want["livemode"]],
               vector["name"]
      else
        assert {:error, %Kuaa.WebhookVerificationError{}} = result, vector["name"]
      end
    end
  end

  test "the real HTTP sends and reads through httpc" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    server = spawn_link(fn -> serve(listener) end)
    base_url = "http://127.0.0.1:#{port}"

    assert {:ok, %Kuaa.CaseTagList{tags: [tag]}} =
             "kuaa_test_abc_secret"
             |> Kuaa.new(base_url: base_url)
             |> Kuaa.CaseTags.create("case 1/2", [tags: ["prioridade"]], idempotency_key: "tag-1")

    assert {tag.name, tag.slug, tag.created_at} ==
             {"prioridade", "tag-1", "POST /v1/cases/case%201%2F2/tags application/json"}

    assert %Kuaa.ResponseInfo{livemode: false, environment: "sandbox"} = Kuaa.last_response()

    assert {:error,
            %Kuaa.Error{status: 401, code: "unauthenticated", retry_after: 3, request_id: "req_401"}} =
             "kuaa_test_other" |> Kuaa.new(base_url: base_url) |> Kuaa.Cases.get("case_1")

    Process.unlink(server)
    Process.exit(server, :kill)
    :gen_tcp.close(listener)
  end

  # Answers each connection as the API would: what it was sent, as a case's
  # tags, or a 401 to another key.
  defp serve(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {head, body} = read(socket, "")
    [request_line | lines] = String.split(head, "\r\n")
    [method, path | _version] = String.split(request_line, " ")

    headers =
      Map.new(lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {status, extra, payload} = respond("#{method} #{path}", headers, body)
    encoded = JSON.encode!(payload)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n",
      extra,
      "Content-Length: #{byte_size(encoded)}\r\nConnection: close\r\n\r\n",
      encoded
    ])

    :gen_tcp.close(socket)
    serve(listener)
  end

  defp read(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length:\s*(\d+)/i, head) do
            [_, digits] -> String.to_integer(digits)
            nil -> 0
          end

        {head, read_body(socket, body, length)}

      [_partial] ->
        {:ok, more} = :gen_tcp.recv(socket, 0)
        read(socket, buffer <> more)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, more} = :gen_tcp.recv(socket, 0)
    read_body(socket, body <> more, length)
  end

  defp respond(request, headers, body) do
    if headers["authorization"] != "Bearer kuaa_test_abc_secret" do
      {401, "Retry-After: 3\r\nX-Request-ID: req_401\r\n",
       %{"error" => %{"code" => "unauthenticated", "message" => "Send a key."}}}
    else
      tags =
        for name <- JSON.decode!(body)["tags"] do
          %{
            "id" => "tag_" <> name,
            "name" => name,
            "slug" => headers["idempotency-key"] || "",
            "created_at" => "#{request} #{headers["content-type"]}"
          }
        end

      {200, "Kuaa-Livemode: false\r\nKuaa-Environment: sandbox\r\n",
       %{"data" => %{"case_id" => "case_1", "tags" => tags}}}
    end
  end
end
