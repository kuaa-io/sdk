defmodule Kuaa.Page do
  @moduledoc """
  One page of a list, and where the next one starts: `next_cursor` is nil on
  the last one, and `has_more` says another page follows.
  """

  @enforce_keys [:items, :next_cursor, :has_more]
  defstruct [:items, :next_cursor, :has_more]

  @type t(item) :: %__MODULE__{items: [item], next_cursor: String.t() | nil, has_more: boolean()}
  @type t :: t(term())

  @doc "Builds a page from the API's envelope, its items under `field`, each through `item`."
  @spec from_envelope(map(), String.t(), (map() -> item)) :: t(item) when item: term()
  def from_envelope(%{} = envelope, field, item) do
    meta = envelope["meta"] || %{}
    next_cursor = meta["next_cursor"]

    has_more =
      case meta["has_more"] do
        more when is_boolean(more) -> more
        _ -> next_cursor not in [nil, ""]
      end

    %__MODULE__{
      items: Enum.map((envelope["data"] || %{})[field] || [], item),
      next_cursor: next_cursor,
      has_more: has_more
    }
  end

  @doc """
  Walks pages from `cursor` (the first page when nil) until the last one,
  emitting every item; `fetch` answers the page of the cursor it is given. A
  refusal raises `Kuaa.Error` while the stream runs.
  """
  @spec stream(
          String.t() | nil,
          (String.t() | nil -> {:ok, t(item)} | {:error, Kuaa.Error.t()})
        ) :: Enumerable.t(item)
        when item: term()
  def stream(cursor, fetch) do
    Stream.resource(
      fn -> {:next, cursor} end,
      fn
        :done ->
          {:halt, :done}

        {:next, at} ->
          case fetch.(at) do
            {:ok, %__MODULE__{items: items, next_cursor: next, has_more: more}} ->
              {items, if(more and next not in [nil, ""], do: {:next, next}, else: :done)}

            {:error, error} ->
              raise error
          end
      end,
      fn _state -> :ok end
    )
  end
end
