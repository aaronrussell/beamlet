defmodule Beamlet.Token do
  @moduledoc """
  A token: the owner's delegation to one client, of one of two kinds,
  carrying the policy its requests run under.

  A `cli` token is minted with `beamlet tokens.create` and named
  there; the name is unique across the beamlet and is lowercase
  letters, digits, underscores and hyphens, since it lands in a git
  trailer and author, and `beamlet` is reserved for the system
  principal (`Beamlet.Principal.system/0`). It never expires and is
  revoked by deleting it. This is how the owner's own code connects.

  An `oauth` token is minted by the token endpoint after a person
  consents in a chat client. `client` holds the client id URL verbatim,
  the identity the redirect was verified against; a client document's
  display name is never stored, since anyone can host a document that
  says "ChatGPT". It carries `expires_at`, and a refresh secret with
  its own expiry that the client redeems for a new pair.

  The kind is a column rather than a reading of which fields are
  null. `label/1` is the display form of either kind, the name or the
  client URL's host, and is what the principal and the provenance
  trailers carry.

  The secrets are random, shown once when the token is created and
  stored only as hashes. `secret` and `refresh_secret` are virtual
  fields: they carry the values on the struct
  `Beamlet.Tokens.create/1` returns and are nil on every token loaded
  afterwards. The policy must be one the beamlet declares
  (`Beamlet.Policies`); a token has `default` when it names none.
  Rows are managed through `Beamlet.Tokens`.
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

  @typedoc "A stored token; the secrets are set only on the struct returned by create."
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
  Changeset for creating or updating a `cli` token: name and policy.
  The name is unique across the beamlet, the policy must be declared
  on the beamlet, and the hash is set by the store, never cast.
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
  Changeset for creating an `oauth` token: the client id, the policy
  chosen at consent, and both expiries. The hashes are set by the
  store, never cast.
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
  Changeset for refreshing an `oauth` token: both expiries anew. The
  client and policy stay as consented, and the hashes are set by the
  store.
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
