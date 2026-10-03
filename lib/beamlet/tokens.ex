defmodule Beamlet.Tokens do
  @moduledoc """
  Creates, updates, lists and deletes tokens from code.

  These are what `beamlet tokens.*` runs. Creating a token is the
  only time its secret is visible:

      {:ok, token} = Beamlet.Tokens.create(name: "laptop", policy: "explorer")
      token.secret
      #=> "wJalrXUtnFEMI_K7MDENG_bPxRfiCYEXAMPLEKEY_q0"

  A client sends the secret as a bearer token.

  `update/2` renames a `cli` token or changes its policy. It refuses
  `oauth` tokens. `delete/1` works on either kind, and the token's
  next request fails.

  The authenticate and rotate functions serve the MCP endpoint and
  the OAuth token endpoint. Most callers will not need them.
  """

  import Ecto.Query

  alias Beamlet.Repo
  alias Beamlet.Secret
  alias Beamlet.Token

  @doc """
  Creates a token.

  `kind` is `:cli` unless given. A `cli` token takes `name` and an
  optional `policy`. An `oauth` token takes `client`, `policy`,
  `expires_at` and `refresh_expires_at`. The policy must be one the
  beamlet declares.

  The returned token carries its `secret`, and an `oauth` token its
  `refresh_secret` too. Nothing else ever will.
  """
  @spec create(map() | keyword()) :: {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    attrs = Map.new(attrs)

    changeset =
      case Map.get(attrs, :kind, :cli) do
        :oauth -> %Token{} |> Token.oauth_changeset(attrs) |> put_secret(:refresh_secret)
        _cli -> Token.cli_changeset(%Token{}, attrs)
      end

    changeset
    |> put_secret(:secret)
    |> Repo.insert()
  end

  @doc """
  Updates a `cli` token's name or policy.

  The secret cannot change, so create a new token instead. An `oauth`
  token cannot be updated and answers `{:error, :oauth_token}`.
  """
  @spec update(Token.t(), map() | keyword()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t() | :oauth_token}
  def update(%Token{kind: :oauth}, _attrs), do: {:error, :oauth_token}

  def update(%Token{} = token, attrs) do
    token
    |> Token.cli_changeset(Map.new(attrs))
    |> Repo.update()
  end

  @doc """
  Deletes a token.

  Requests presenting its secret fail from then on.
  """
  @spec delete(Token.t()) :: {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Token{} = token), do: Repo.delete(token)

  @doc "Every token on the beamlet, oldest first."
  @spec list() :: [Token.t()]
  def list, do: Repo.all(from(t in Token, order_by: t.id))

  @doc "Finds a token by id."
  @spec find(pos_integer()) :: {:ok, Token.t()} | {:error, :not_found}
  def find(id) do
    case Repo.get(Token, id) do
      nil -> {:error, :not_found}
      %Token{} = token -> {:ok, token}
    end
  end

  @doc """
  Turns a presented secret into its token.

  Anything that is not the secret of a stored token, including a
  deleted token's secret or a value that never was one, is
  `{:error, :unknown_token}`. The secret of an `oauth` token past its
  expiry is `{:error, :expired_token}`.
  """
  @spec authenticate(term()) :: {:ok, Token.t()} | {:error, :unknown_token | :expired_token}
  def authenticate(secret) when is_binary(secret) do
    case Repo.get_by(Token, secret_hash: Secret.hash(secret)) do
      nil -> {:error, :unknown_token}
      %Token{expires_at: nil} = token -> {:ok, token}
      %Token{expires_at: expires_at} = token -> expiring(token, expires_at)
    end
  end

  def authenticate(_other), do: {:error, :unknown_token}

  @doc """
  Turns a presented refresh secret into its `oauth` token, for the
  token endpoint.

  Anything that is not the refresh secret of a stored token, a `cli`
  token's secret among them, is `{:error, :unknown_token}`. A refresh
  secret past `refresh_expires_at` is `{:error, :expired_token}`.
  """
  @spec authenticate_refresh(term()) ::
          {:ok, Token.t()} | {:error, :unknown_token | :expired_token}
  def authenticate_refresh(secret) when is_binary(secret) do
    case Repo.get_by(Token, refresh_hash: Secret.hash(secret)) do
      nil -> {:error, :unknown_token}
      %Token{refresh_expires_at: expires_at} = token -> expiring(token, expires_at)
    end
  end

  def authenticate_refresh(_other), do: {:error, :unknown_token}

  @doc """
  Rotates an `oauth` token in place, with new secrets and expiries.

  `attrs` carries `expires_at` and `refresh_expires_at`. The row and
  its id stay, so provenance keeps pointing at the same token. The
  old secrets stop working at once, and the returned token carries
  the new `secret` and `refresh_secret`. A `cli` token answers
  `{:error, :cli_token}`.

  A refresh secret redeems once. The rotation only lands while the
  row still holds the refresh secret `token` was loaded with, so of
  two rotations from one secret the second answers
  `{:error, :unknown_token}`, as a spent secret does.
  """
  @spec rotate(Token.t(), map() | keyword()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t() | :cli_token | :unknown_token}
  def rotate(%Token{kind: :cli}, _attrs), do: {:error, :cli_token}

  def rotate(%Token{kind: :oauth, id: id, refresh_hash: refresh_hash} = token, attrs) do
    changeset =
      token
      |> Token.rotate_changeset(Map.new(attrs))
      |> put_secret(:secret)
      |> put_secret(:refresh_secret)
      |> Ecto.Changeset.put_change(:updated_at, NaiveDateTime.utc_now(:second))

    with {:ok, rotated} <- Ecto.Changeset.apply_action(changeset, :update) do
      changes = changeset.changes |> Map.drop([:secret, :refresh_secret]) |> Keyword.new()
      query = from(t in Token, where: t.id == ^id and t.refresh_hash == ^refresh_hash)

      case Repo.update_all(query, set: changes) do
        {1, _rows} -> {:ok, rotated}
        {0, _rows} -> {:error, :unknown_token}
      end
    end
  end

  defp expiring(token, expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: {:ok, token},
      else: {:error, :expired_token}
  end

  defp put_secret(changeset, field) do
    secret = Secret.generate()
    hash_field = if field == :secret, do: :secret_hash, else: :refresh_hash

    changeset
    |> Ecto.Changeset.put_change(hash_field, Secret.hash(secret))
    |> Ecto.Changeset.put_change(field, secret)
  end
end
