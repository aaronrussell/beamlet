defmodule Beamlet.KV.Entry do
  @moduledoc false

  # One row of the key/value store behind Host.KV: a string key and
  # the JSON text of its value, which Host.KV encodes and decodes.
  # The table is created at boot by Beamlet.Tables.

  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "__kv" do
    field :value, :string
  end

  @type t :: %__MODULE__{key: String.t(), value: String.t()}
end
