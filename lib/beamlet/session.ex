defmodule Beamlet.Session do
  @moduledoc """
  A session: one browser signed in to the app as the owner.

  Signing in on the web creates a session and hands its secret to the
  browser in the app's own cookie (`Beamlet.Web.Auth`); every request
  turns the secret back into the user. Only the hash is stored, so a
  cookie is worth nothing unless its secret matches a row, and a
  signature forged with the endpoint's `secret_key_base` buys nothing.
  Signing out deletes the session, and setting a new password deletes
  them all.

  `secret` is a virtual field: it carries the value on the struct
  `Beamlet.Owner.create_session/0` returns and is nil on every session
  loaded afterwards. Rows are managed through `Beamlet.Owner`.
  """

  use Ecto.Schema

  schema "sessions" do
    field(:secret, :string, virtual: true, redact: true)
    field(:secret_hash, :binary, redact: true)
    timestamps()
  end

  @typedoc "A stored session; the secret is set only on the struct returned by create."
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          secret: String.t() | nil,
          secret_hash: binary() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }
end
