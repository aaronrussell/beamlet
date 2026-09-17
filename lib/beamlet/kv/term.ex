defmodule Beamlet.KV.Term do
  @moduledoc false

  # An Ecto type for any Elixir term, stored as a binary in Erlang's
  # external term format: the value column of the key/value store.
  # Any term casts; it comes back exactly as stored. A parameterized
  # type rather than an Ecto.Type because only parameterized types
  # see nil: Ecto.Type maps nil to NULL before dump, and nil is a
  # value here, not an absence.

  use Ecto.ParameterizedType

  @impl true
  def init(_opts), do: %{}

  @impl true
  def type(_params), do: :binary

  @impl true
  def cast(term, _params), do: {:ok, term}

  @impl true
  def dump(term, _dumper, _params), do: {:ok, :erlang.term_to_binary(term)}

  # Not :safe: the beamlet wrote the bytes, and :safe would refuse a
  # value holding an atom from an agent module removed since.
  @impl true
  def load(binary, _loader, _params) when is_binary(binary),
    do: {:ok, :erlang.binary_to_term(binary)}
end
