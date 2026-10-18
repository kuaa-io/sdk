defmodule Kuaa.WebhookVerificationError do
  @moduledoc "A delivery KUAA did not sign with the secret, or signed too long ago."

  defexception message: "kuaa: webhook signature does not verify"

  @type t :: %__MODULE__{message: String.t()}
end

defmodule Kuaa.WebhookSignature do
  @moduledoc """
  Verifying the webhooks KUAA sends.

      {:ok, event} = Kuaa.WebhookSignature.verify(secret, conn.req_headers, raw_body)
  """

  @tolerance_seconds 300
  @max_signatures 6

  @doc "The header with the delivery id, the same on every retry."
  @spec header_delivery_id() :: String.t()
  def header_delivery_id, do: "X-Arandu-Delivery-Id"

  @doc "The header with the Unix time, in seconds, the attempt was signed at."
  @spec header_timestamp() :: String.t()
  def header_timestamp, do: "X-Arandu-Timestamp"

  @doc "The header with the signatures, one line per secret still signing."
  @spec header_signature() :: String.t()
  def header_signature, do: "X-Arandu-Signature"

  @doc "How far from now a delivery's timestamp may be, either way, in seconds."
  @spec tolerance_seconds() :: pos_integer()
  def tolerance_seconds, do: @tolerance_seconds

  @doc """
  Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0
  envelope.

  The signature is
  `sha256=hex(HMAC-SHA256(secret, timestamp <> "." <> delivery_id <> "." <> body))`,
  keyed with the endpoint's secret exactly as it was shown; during a rotation
  the X-Arandu-Signature header comes once per secret, and any one matching is
  enough. A timestamp more than five minutes from now is refused. Pass the
  body exactly as it arrived, before parsing it; `headers` is a map or a list
  of name and value pairs (a value may be a list of lines), names in any case.
  The option `:now` is the Unix time, or a `DateTime`, to check the timestamp
  against. Deduplicate on the event's id: delivery is at least once.
  """
  @spec verify(String.t(), Enumerable.t(), binary(), keyword()) ::
          {:ok, Kuaa.WebhookEvent.t()} | {:error, Kuaa.WebhookVerificationError.t()}
  def verify(secret, headers, body, opts \\ []) when is_binary(body) do
    if secret in [nil, ""], do: raise(ArgumentError, "kuaa: the webhook secret is empty")

    now = opts |> Keyword.get_lazy(:now, fn -> System.os_time(:second) end) |> unix()
    delivery = headers |> values(header_delivery_id()) |> first()
    stamp = headers |> values(header_timestamp()) |> first()
    signature = headers |> values(header_signature()) |> Enum.join(",")
    entries = String.split(signature, ",")

    with true <- delivery != "",
         true <- stamp =~ ~r/\A[0-9]+\z/,
         true <- abs(now - String.to_integer(stamp)) <= @tolerance_seconds,
         true <- String.trim(signature) != "" and length(entries) <= @max_signatures,
         {:ok, given} <- decode_all(entries),
         expected = :crypto.mac(:hmac, :sha256, secret, [stamp, ".", delivery, ".", body]),
         true <- Enum.reduce(given, false, &(:crypto.hash_equals(&1, expected) or &2)),
         {:ok, %{} = event} <- JSON.decode(body) do
      {:ok, Kuaa.WebhookEvent.from_map(event)}
    else
      _ -> {:error, %Kuaa.WebhookVerificationError{}}
    end
  end

  defp decode_all(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with "sha256=" <> digest <- String.trim(entry),
           true <- byte_size(digest) == 64,
           {:ok, decoded} <- Base.decode16(digest, case: :mixed) do
        {:cont, {:ok, [decoded | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp first([value | _rest]), do: String.trim(value)
  defp first([]), do: ""

  defp values(headers, name) do
    wanted = String.downcase(name)

    Enum.flat_map(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == wanted,
        do: value |> List.wrap() |> Enum.map(&to_string/1),
        else: []
    end)
  end

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)
  defp unix(seconds) when is_integer(seconds), do: seconds
end
