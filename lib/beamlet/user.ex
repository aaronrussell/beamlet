defmodule Beamlet.User do
  @moduledoc """
  A user on a beamlet: the durable name the operator creates and the
  history refers to.

  Nothing else lives here. No roles, no email, no login. Credentials
  are tokens (`Beamlet.Token`), and a user has as many as they have
  clients. Rows are managed through `Beamlet.Users`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field(:name, :string)
    timestamps()
  end

  @typedoc "A stored user."
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          name: String.t() | nil,
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
