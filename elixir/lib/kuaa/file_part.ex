defmodule Kuaa.FilePart do
  @moduledoc """
  One file of a multipart body: `filename` is the name the part carries, such
  as frente.jpg, and `content_type` the file's media type, image/jpeg or
  image/png.
  """

  @enforce_keys [:filename, :data]
  defstruct [:filename, :data, content_type: "application/octet-stream"]

  @type t :: %__MODULE__{filename: String.t(), data: binary(), content_type: String.t()}

  @doc "A file read from disk."
  @spec from_path(Path.t(), String.t()) :: t()
  def from_path(path, content_type \\ "application/octet-stream") do
    %__MODULE__{filename: Path.basename(path), data: File.read!(path), content_type: content_type}
  end
end

defmodule Kuaa.ResponseInfo do
  @moduledoc """
  What the API said about an answer, beside its body: `livemode` is the
  Kuaa-Livemode header (true for live, false for a sandbox, nil when absent),
  `environment` the Kuaa-Environment header, `idempotent_replayed` says the
  answer is the stored answer of an earlier request with the same
  Idempotency-Key, and `request_id` is the X-Request-ID header.
  """

  @enforce_keys [:status]
  defstruct [:status, :livemode, :environment, :request_id, idempotent_replayed: false]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          livemode: boolean() | nil,
          environment: String.t() | nil,
          idempotent_replayed: boolean(),
          request_id: String.t() | nil
        }

  @doc "The info of an answer's status and headers, names in lower case."
  @spec from_headers(non_neg_integer(), [{String.t(), String.t()}]) :: t()
  def from_headers(status, headers) do
    value = fn name ->
      case List.keyfind(headers, name, 0) do
        {_name, value} -> value
        nil -> nil
      end
    end

    %__MODULE__{
      status: status,
      livemode: Map.get(%{"true" => true, "false" => false}, value.("kuaa-livemode")),
      environment: value.("kuaa-environment"),
      idempotent_replayed: value.("idempotent-replayed") == "true",
      request_id: value.("x-request-id")
    }
  end
end
