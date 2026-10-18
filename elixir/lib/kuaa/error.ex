defmodule Kuaa.Error do
  @moduledoc """
  A request the API refused.

  `code` is the API's, the one to branch on: `unauthenticated`, `forbidden`,
  `not_found`, `conflict`, `idempotency_key_reused`, `validation_failed`,
  `payment_required`, `malformed_json`, `body_too_large`, `rate_limited`…
  `message` is the API's explanation, `fields` says, for `validation_failed`,
  what is wrong with each field, and `retry_after` is how many seconds the
  API asked to wait, on a 429 or a 503.

  A request that never got an answer has no `status` and the code `transport`.
  """

  defexception [:status, code: "", message: "", fields: %{}, retry_after: nil, request_id: nil]

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          code: String.t(),
          message: String.t(),
          fields: %{optional(String.t()) => [String.t()]},
          retry_after: non_neg_integer() | nil,
          request_id: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{status: status, code: code, message: ""}),
    do: "kuaa: #{status} #{code}"

  def message(%__MODULE__{status: status, code: code, message: message}),
    do: "kuaa: #{status} #{code}: #{message}"

  @doc "The error a response with a status of 300 or more is."
  @spec from_response(non_neg_integer(), [{String.t(), String.t()}], binary()) :: t()
  def from_response(status, headers, body) do
    problem =
      case JSON.decode(body) do
        {:ok, %{"error" => %{} = problem}} -> problem
        # A refusal without a JSON body is still a refusal.
        _ -> %{}
      end

    %__MODULE__{
      status: status,
      code: string(problem["code"]),
      message: string(problem["message"]),
      fields: problem["fields"] || %{},
      retry_after: retry_after(headers),
      request_id: header(headers, "x-request-id")
    }
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  defp retry_after(headers) do
    with value when is_binary(value) <- header(headers, "retry-after"),
         {seconds, ""} <- value |> String.trim() |> Integer.parse() do
      seconds
    else
      _ -> nil
    end
  end
end
