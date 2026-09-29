defmodule Beamlet.Session do
  @moduledoc """
  A session: one browser signed in to the app as one user.

  Signing in on the web creates a session and hands its secret to the
  browser in the app's own cookie (`Beamlet.Web.Auth`); every request
  turns the secret back into the session and its user. Only the hash
  is stored, so a cookie is worth nothing unless its secret matches a
  row, and a signature forged with the endpoint's `secret_key_base`
  buys nothing. Signing out deletes the session, as do resetting the
  user's password and deleting the user.

  `secret` is a virtual field: it carries the value on the struct
  `Beamlet.Users.create_session/1` returns and is nil on every session
  loaded afterwards. Rows are managed through `Beamlet.Users`.
  """

  use Ecto.Schema

  alias Beamlet.User

  schema "sessions" do
    belongs_to(:user, User)
    field(:secret, :string, virtual: true, redact: true)
    field(:secret_hash, :binary, redact: true)
    timestamps()
  end

  @typedoc "A stored session; the secret is set only on the struct returned by create."
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          user_id: pos_integer() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          secret: String.t() | nil,
          secret_hash: binary() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }
end
