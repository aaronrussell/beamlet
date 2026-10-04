defmodule Beamlet.Token do
  @moduledoc """
  The credential one client uses to reach your beamlet.

  A token is one of two kinds:

  * `cli` - Named, and created with `beamlet tokens.create` or
    `Beamlet.Tokens.create/1`. It never expires and lasts until you
    delete it.
  * `oauth` - Created when a chat client connects and you consent.
    It is known by the client's URL, and it expires and refreshes
    as `Beamlet.OAuth` describes.

  Each token has a policy, `default` unless another was named.

  The secret is set only on the struct that creating the token
  returns. The beamlet keeps just a hash, so `secret` is `nil` on
  every token loaded afterwards, and a lost secret means a new token.

  `label/1` is the name the beamlet shows for a token: a `cli`
  token's name, or an `oauth` token's client host.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "tokens" do
    field(:kind, Ecto.Enum, values: [:cli, :oauth], default: :cli)
    field(:name, :string)
    field(:client, :string)
    field(:policy, :string, default: "default")
    field(:secret, :string, virtual: true)
    field(:secret_hash, :binary)
    field(:expires_at, :utc_datetime)
    field(:refresh_secret, :string, virtual: true)
    field(:refresh_hash, :binary)
    field(:refresh_expires_at, :utc_datetime)
    timestamps()
  end

  @typedoc "A token's kind: `cli`, minted from the command line, or `oauth`, minted at consent."
  @type kind :: :cli | :oauth

  @typedoc """
  A token as stored.

  The secrets are set only on the struct `Beamlet.Tokens.create/1`
  returns.
  """
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          kind: kind(),
          name: String.t() | nil,
          client: String.t() | nil,
          policy: String.t(),
          secret: String.t() | nil,
          secret_hash: binary() | nil,
          expires_at: DateTime.t() | nil,
          refresh_secret: String.t() | nil,
          refresh_hash: binary() | nil,
          refresh_expires_at: DateTime.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @doc """
  Changeset for creating or updating a `cli` token.

  It casts the name and policy. The name must be unique on the
  beamlet and the policy one it declares. The hash is set by
  `Beamlet.Tokens`, never cast.
  """
  @spec cli_changeset(t(), map()) :: Ecto.Changeset.t()
  def cli_changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :policy])
    |> put_change(:kind, :cli)
    |> validate_name()
    |> validate_exclusion(:name, ["beamlet"], message: "is reserved for the beamlet itself")
    |> validate_required([:policy])
    |> validate_policy()
    |> unique_constraint(:name, message: "is already a token name on this beamlet")
  end

  @doc """
  Changeset for creating an `oauth` token.

  It casts the client id, the policy chosen at consent and both
  expiries. The hashes are set by `Beamlet.Tokens`, never cast.
  """
  @spec oauth_changeset(t(), map()) :: Ecto.Changeset.t()
  def oauth_changeset(token, attrs) do
    token
    |> cast(attrs, [:client, :policy, :expires_at, :refresh_expires_at])
    |> put_change(:kind, :oauth)
    |> validate_required([:client, :policy, :expires_at, :refresh_expires_at])
    |> validate_policy()
  end

  @doc """
  Changeset for refreshing an `oauth` token.

  It casts both expiries. The client and policy stay as consented,
  and the hashes are set by `Beamlet.Tokens`.
  """
  @spec rotate_changeset(t(), map()) :: Ecto.Changeset.t()
  def rotate_changeset(%__MODULE__{kind: :oauth} = token, attrs) do
    token
    |> cast(attrs, [:expires_at, :refresh_expires_at])
    |> validate_required([:expires_at, :refresh_expires_at])
  end

  @doc "The display form of a token: a `cli` token's name, or the host of an `oauth` token's client id."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{kind: :cli, name: name}), do: name

  def label(%__MODULE__{kind: :oauth, client: client}) do
    case URI.parse(client) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> client
    end
  end

  defp validate_name(changeset) do
    changeset
    |> validate_required([:name])
    |> validate_length(:name, max: 64)
    |> validate_format(:name, ~r/^[a-z0-9_-]+$/,
      message: "must be lowercase letters, digits, underscores and hyphens only"
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
