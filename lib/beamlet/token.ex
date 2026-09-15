defmodule Beamlet.Token do
  @moduledoc """
  A token: a credential belonging to one user, with a name and the
  policy its requests run under.

  The secret is random, shown once when the token is created and
  stored only as a hash. `secret` is a virtual field: it carries the
  value on the struct `Beamlet.Users.create_token/2` returns and is nil on
  every token loaded afterwards. A user holds one token per client or
  device, and two policies for one person means two tokens. The
  policy must be one the beamlet declares (`Beamlet.Policies`); a
  token has `default` when it names none. Rows are managed through
  `Beamlet.Users`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Beamlet.User

  schema "tokens" do
    belongs_to(:user, User)
    field(:name, :string)
    field(:policy, :string, default: "default")
    field(:secret, :string, virtual: true)
    field(:secret_hash, :binary)
    timestamps()
  end

  @typedoc "A stored token; `secret` is set only on the struct returned by create."
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          user_id: pos_integer() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          name: String.t() | nil,
          policy: String.t(),
          secret: String.t() | nil,
          secret_hash: binary() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @doc """
  Changeset for creating or updating a token: name and policy. The
  name is unique per user, the policy must be declared on the
  beamlet, and the hash is set by the store, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :policy])
    |> User.validate_name()
    |> validate_required([:policy])
    |> validate_policy()
    |> unique_constraint([:user_id, :name],
      error_key: :name,
      message: "is already a token name for this user"
    )
  end

  defp validate_policy(changeset) do
    validate_change(changeset, :policy, fn :policy, name ->
      names = Beamlet.Policies.names()

      if name in names do
        []
      else
        [policy: "#{name} is not a policy on this beamlet (declared: #{Enum.join(names, ", ")})"]
      end
    end)
  end
end
