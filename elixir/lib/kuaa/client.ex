defmodule Kuaa.Client do
  @moduledoc """
  KUAA's API with one organization's API key.

  The key says the organization and the environment: `kuaa_<prefix>_<secret>`
  is live, `kuaa_test_<prefix>_<secret>` the organization's sandbox.

      client = Kuaa.Client.new(System.fetch_env!("KUAA_API_KEY"))
      {:ok, kase} = Kuaa.Cases.get(client, "case_1")
      Kuaa.Client.last_response().livemode
  """

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key]
  defstruct [
    :api_key,
    base_url: Kuaa.default_base_url(),
    timeout: 30_000,
    transport: &Kuaa.Client.httpc/5
  ]

  @typedoc """
  Sends one request: `(method, url, headers, body, timeout_ms)` answers
  `{:ok, {status, headers_in_lower_case, body}}` or `{:error, reason}`.
  """
  @type transport ::
          (String.t(), String.t(), [{String.t(), String.t()}], binary() | nil, timeout() ->
             {:ok, {non_neg_integer(), [{String.t(), String.t()}], binary()}} | {:error, term()})

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: timeout(),
          transport: transport()
        }

  @last_response :kuaa_last_response

  @doc """
  A client for the organization `api_key` belongs to.

  Options: `:base_url` (another address, such as a local server), `:timeout`
  in milliseconds (30 seconds) and `:transport` (see `t:transport/0`).
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) do
    %__MODULE__{
      api_key: api_key,
      base_url:
        opts |> Keyword.get(:base_url, Kuaa.default_base_url()) |> String.trim_trailing("/"),
      timeout: Keyword.get(opts, :timeout, 30_000),
      transport: Keyword.get(opts, :transport, &__MODULE__.httpc/5)
    }
  end

  @doc """
  What the API said about the last answer this process read, or nil before
  the first one. It is kept per process, so concurrent callers never see each
  other's.
  """
  @spec last_response() :: Kuaa.ResponseInfo.t() | nil
  def last_response, do: Process.get(@last_response)

  @doc """
  Calls the API and answers its envelope: `data`, and a list's `meta`.

  Options: `:query`, `:body`, `:multipart` (the body as
  multipart/form-data), `:idempotency_key` and `:api_key`, another key for
  this call.
  """
  @spec request(t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Kuaa.Error.t()}
  def request(%__MODULE__{} = client, method, path, opts \\ []) do
    {body, content_type} = encode(opts[:body], opts[:multipart])

    headers =
      [
        {"Authorization", "Bearer " <> key(opts[:api_key], client.api_key)},
        {"Accept", "application/json"},
        {"User-Agent", "kuaa-elixir/" <> Kuaa.version()}
      ]
      |> put_header("Content-Type", content_type)
      |> put_header("Idempotency-Key", opts[:idempotency_key])

    url = client.base_url <> path <> query(opts[:query])

    case client.transport.(method, url, headers, body, client.timeout) do
      {:ok, {status, response_headers, raw}} ->
        Process.put(@last_response, Kuaa.ResponseInfo.from_headers(status, response_headers))
        answer(status, response_headers, raw)

      {:error, reason} ->
        {:error, %Kuaa.Error{status: nil, code: "transport", message: inspect(reason)}}
    end
  end

  defp answer(status, headers, raw) when status >= 300,
    do: {:error, Kuaa.Error.from_response(status, headers, raw)}

  defp answer(status, _headers, raw) do
    case JSON.decode(raw) do
      {:ok, %{} = envelope} ->
        {:ok, envelope}

      _ ->
        {:error,
         %Kuaa.Error{
           status: status,
           code: "malformed_response",
           message: "the answer is not a JSON object"
         }}
    end
  end

  defp encode(nil, _multipart), do: {nil, nil}
  defp encode(body, true), do: multipart(body)
  defp encode(body, _multipart), do: {JSON.encode!(body), "application/json"}

  @doc """
  A body as multipart/form-data: a list repeats its name, a `Kuaa.FilePart`
  is a file part. Answers the body and its Content-Type.
  """
  @spec multipart(map()) :: {binary(), String.t()}
  def multipart(%{} = body) do
    boundary = "kuaa-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    parts =
      for {name, value} <- body, each <- List.wrap(value), not is_nil(each) do
        ["--", boundary, "\r\n", part(to_string(name), each), "\r\n"]
      end

    {IO.iodata_to_binary([parts, "--", boundary, "--\r\n"]),
     "multipart/form-data; boundary=" <> boundary}
  end

  defp part(name, %Kuaa.FilePart{} = file) do
    [
      ~s(Content-Disposition: form-data; name="#{escape(name)}"; filename="#{escape(file.filename)}"\r\n),
      "Content-Type: ",
      file.content_type,
      "\r\n\r\n",
      file.data
    ]
  end

  defp part(name, value),
    do: [~s(Content-Disposition: form-data; name="#{escape(name)}"\r\n\r\n), to_string(value)]

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
  end

  @doc false
  # A path parameter, escaped.
  @spec segment(String.t()) :: String.t()
  def segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp key(override, _default) when is_binary(override) and override != "", do: override
  defp key(_override, default), do: default

  defp put_header(headers, _name, value) when value in [nil, false, ""], do: headers
  defp put_header(headers, name, value), do: headers ++ [{name, value}]

  defp query(nil), do: ""

  defp query(values) do
    pairs =
      for {name, value} <- values,
          each <- List.wrap(value),
          each not in [nil, ""],
          do: {to_string(name), to_string(each)}

    case pairs do
      [] -> ""
      kept -> "?" <> URI.encode_query(kept, :rfc3986)
    end
  end

  @doc """
  The standard library's HTTP, `:httpc`, so the SDK depends on nothing. HTTPS
  verifies the server against the operating system's certificates.
  """
  @spec httpc(String.t(), String.t(), [{String.t(), String.t()}], binary() | nil, timeout()) ::
          {:ok, {non_neg_integer(), [{String.t(), String.t()}], binary()}} | {:error, term()}
  def httpc(method, url, headers, body, timeout) do
    {:ok, _started} = Application.ensure_all_started([:inets, :ssl])
    {content_type, headers} = List.keytake(headers, "Content-Type", 0) || {nil, headers}

    headers =
      for {name, value} <- headers, do: {String.to_charlist(name), String.to_charlist(value)}

    url = String.to_charlist(url)

    request =
      case {body, content_type} do
        {nil, _} when method in ["GET", "DELETE"] -> {url, headers}
        {nil, _} -> {url, headers, ~c"", ""}
        {body, {_name, type}} -> {url, headers, String.to_charlist(type), body}
      end

    options = [timeout: timeout, connect_timeout: timeout, autoredirect: false, ssl: ssl(url)]

    case :httpc.request(verb(method), request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, raw}} ->
        {:ok,
         {status, for({name, value} <- response_headers, do: {to_string(name), to_string(value)}),
          raw}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verb("GET"), do: :get
  defp verb("POST"), do: :post
  defp verb("PUT"), do: :put
  defp verb("PATCH"), do: :patch
  defp verb("DELETE"), do: :delete

  defp ssl(~c"https://" ++ _rest) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ssl(_url), do: []
end
