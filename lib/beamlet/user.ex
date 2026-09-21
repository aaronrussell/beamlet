defmodule Beamlet.User do
  @moduledoc """
  A user on a beamlet: the durable name the operator creates and the
  history refers to.

  A user who has a password can sign in on the web
  (`Beamlet.Web.SessionController`); one without cannot, and the
  operator sets or resets it with `beamlet users.update --password`.
  Nothing else lives here: no roles, no email. Credentials for agents
  are tokens (`Beamlet.Token`), and a user has as many as they have
  clients. Rows are managed through `Beamlet.Users`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field(:name, :string)
    field(:password, :string, virtual: true, redact: true)
    field(:password_hash, :string, redact: true)
    timestamps()
  end

  @typedoc "A stored user; `password` is virtual and never set on a loaded struct."
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          name: String.t() | nil,
          password: String.t() | nil,
          password_hash: String.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @doc """
  Changeset for creating or updating a user; the name must be unique,
  and `beamlet` is reserved for the system principal
  (`Beamlet.Principal.system/0`).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_name()
    |> validate_exclusion(:name, ["beamlet"], message: "is reserved for the beamlet itself")
    |> unique_constraint(:name)
  end

  @doc """
  Changeset for setting a password: 8 to 128 characters, stored only
  as a PBKDF2 hash.
  """
  @spec password_changeset(t(), map()) :: Ecto.Changeset.t()
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 128)
    |> hash_password()
  end

  defp hash_password(changeset) do
    case fetch_change(changeset, :password) do
      {:ok, password} when changeset.valid? ->
        changeset
        |> put_change(:password_hash, Pbkdf2.hash_pwd_salt(password))
        |> delete_change(:password)

      _other ->
        changeset
    end
  end

  @doc """
  Validates a name field: required, at most 64 characters, lowercase
  letters, digits, underscores and hyphens. Shared with tokens.
  """
  @spec validate_name(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_name(changeset, field \\ :name) do
    format_regx = ~r/^[a-z0-9_-]+$/
    error_msg = "must be lowercase letters, digits, underscores and hyphens only"

    changeset
    |> validate_required([field])
    |> validate_length(field, max: 64)
    |> validate_format(field, format_regx, message: error_msg)
  end
end
