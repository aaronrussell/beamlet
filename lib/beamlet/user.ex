defmodule Beamlet.User do
  @moduledoc false

  # The beamlet's one user, its owner: the email and password that sign
  # in on the web.
  #
  # A beamlet belongs to one person. The row is created by the first
  # `beamlet setup` and updated by every one after; the database holds
  # at most one. The email is the sign-in identifier, stored trimmed
  # and lowercased; it is never verified and never mailed. The password
  # is stored only as a hash. Credentials for agents are tokens
  # (`Beamlet.Token`), which belong to the beamlet rather than to this
  # row. Managed through `Beamlet.Owner`.

  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    timestamps()
  end

  @typedoc "The stored user; `password` is virtual and never set on a loaded struct."
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          email: String.t() | nil,
          password: String.t() | nil,
          password_hash: String.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @doc """
  Changeset for creating or updating the user: the email, and a
  password of at least 8 characters and at most `max_password_bytes/0`
  bytes, stored only as a PBKDF2 hash.

  The password is required when the user has none yet and optional
  after, so an update may change the email alone. A second user is
  refused: a beamlet has one.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> update_change(:email, &(&1 && normalize_email(&1)))
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+$/, message: "must look like name@example.com")
    |> validate_length(:email, max: 160)
    |> validate_password()
    |> check_constraint(:id,
      name: :one_user,
      message: "is taken: a beamlet has one user; update it instead"
    )
  end

  @doc "An email in the form it is stored and compared in: trimmed and lowercased."
  @spec normalize_email(String.t()) :: String.t()
  def normalize_email(email), do: email |> String.trim() |> String.downcase()

  @doc """
  The longest password the user may have, in bytes.

  Counted in bytes because PBKDF2's cost grows with the password's
  byte length, and sign-in refuses anything longer before hashing it.
  """
  @spec max_password_bytes() :: pos_integer()
  def max_password_bytes, do: 128

  defp validate_password(changeset) do
    changeset =
      if get_field(changeset, :password_hash),
        do: changeset,
        else: validate_required(changeset, [:password])

    changeset
    |> validate_length(:password, min: 8)
    |> validate_length(:password, max: max_password_bytes(), count: :bytes)
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
end
