defmodule Beamlet.KV.Entry do
  @moduledoc false

  # One row of the key/value store behind Host.KV: a string key and
  # its value, any Elixir term, stored in external term format
  # (Beamlet.KV.Term). The table is created at boot by Beamlet.Tables.

  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "__kv" do
    field(:value, Beamlet.KV.Term)
  end

  @type t :: %__MODULE__{key: String.t(), value: term()}
end
