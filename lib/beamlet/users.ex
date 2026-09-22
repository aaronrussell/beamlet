defmodule Beamlet.Users do
  @moduledoc """
  Users and their tokens: the operator's store for who may work on a
  beamlet and with what credentials.

  A user is a durable name (`Beamlet.User`); a token is a credential
  belonging to one user, carrying the policy its requests run under
  (`Beamlet.Token`). A token is one of two kinds: `cli`, named and
  minted here by the operator, or `oauth`, minted when a person
  consents in a chat client. Creating a token is the one moment its
  secret is visible:

      {:ok, user} = Beamlet.Users.create(%{name: "alice"})
      {:ok, token} = Beamlet.Users.create_token(user, %{name: "laptop"})
      token.secret
      #=> "wJalrXUtnFEMI_K7MDENG_bPxRfiCYEXAMPLEKEY_q0"

  The secret is what a client sends as its bearer credential. Only its
  hash is stored, so `authenticate/1` is how a request finds its token
  and user, and a lost secret means a new token. A `cli` token never
  expires; an `oauth` token expires at `expires_at` and is refreshed
  by the token endpoint. Policy attaches to the token, not the user: a
  token names one and has `default` when it names none, and the name
  must be a policy the beamlet declares (`Beamlet.Policies`). A user
  bounds which: `policies/1` is the list a user's tokens may carry,
  the user's own `policies` or every declared one when that list is
  empty, and `create_token/2` and `update_token/2` refuse a policy
  outside it. The command line, the consent page and the token
  endpoint all mint through those two functions, so this is the one
  gate; `Beamlet.MCP.Plug` applies the same bound on every request,
  so narrowing a user's list takes effect at once.

  A user signs in on the web with a password the operator sets
  (`update_password/2`); `authenticate_password/2` is how the sign-in
  form finds the user, and a user with no password cannot sign in.
  The password is stored only as a hash. A web sign-in is a user on a
  request and nothing more: no token and no policy, since a browser
  authors no code.

  Operator-only. Nothing under `Host.*` reaches these functions, and
  deleting a user deletes their tokens with them. The command line
  over these functions is `Beamlet.CLI`, reached as `mix beamlet` in
  development.
  """

  import Ecto.Query

  alias Beamlet.Repo
  alias Beamlet.Token
  alias Beamlet.User

  @doc "Creates a user from attrs; the name must be lowercase letters, digits, underscores and hyphens."
  @spec create(map() | keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert()
  end

  @doc """
  Updates a user's name or policy list; the id, and everything keyed
  on it, stays. A new list replaces the old one whole, and a token
  whose policy falls outside it is refused by `Beamlet.MCP.Plug` from
  the next request on.
  """
  @spec update(User.t(), map() | keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update(%User{} = user, attrs) do
    user
    |> User.changeset(Map.new(attrs))
    |> Repo.update()
  end

  @doc """
  The policy names a user's tokens may carry: the user's own list in
  the order the operator gave it, or every declared policy when that
  list is empty.
  """
  @spec policies(User.t()) :: [String.t()]
  def policies(%User{policies: []}), do: Beamlet.Policies.names()
  def policies(%User{policies: policies}), do: policies

  @doc "Deletes a user and every token they hold."
  @spec delete(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def delete(%User{} = user), do: Repo.delete(user)

  @doc "All users, oldest first."
  @spec list() :: [User.t()]
  def list, do: Repo.all(from(u in User, order_by: u.id))

  @doc "Finds a user by id."
  @spec find(pos_integer()) :: {:ok, User.t()} | {:error, :not_found}
  def find(id), do: wrap(Repo.get(User, id))

  @doc "Finds the one user matching the clauses, such as `name: \"alice\"`."
  @spec find_by(keyword()) :: {:ok, User.t()} | {:error, :not_found}
  def find_by(clauses), do: wrap(Repo.get_by(User, clauses))

  @doc "Sets or resets a user's password, 8 to 128 characters; only its hash is stored."
  @spec update_password(User.t(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_password(%User{} = user, password) do
    user
    |> User.password_changeset(%{password: password})
    |> Repo.update()
  end

  @doc """
  Turns a name and password into the user, for the sign-in form.

  A wrong password, an unknown name and a user with no password all
  fail the same way, `{:error, :invalid_credentials}`, and take the
  same time, so the reply reveals nothing about which.
  """
  @spec authenticate_password(term(), term()) :: {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate_password(name, password) when is_binary(name) and is_binary(password) do
    case Repo.get_by(User, name: name) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Pbkdf2.verify_pass(password, hash),
          do: {:ok, user},
          else: {:error, :invalid_credentials}

      _other ->
        Pbkdf2.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  def authenticate_password(_name, _password), do: {:error, :invalid_credentials}

  @doc """
  Creates a token for a user. `kind` picks the shape and is `cli` when
  absent: a `cli` token takes `name` and an optional `policy`; an
  `oauth` token takes `client`, `policy`, `expires_at` and
  `refresh_expires_at`.

  The policy must be one the user may carry (`policies/1`); a
  bounded user whose list lacks `default` gets no default, so a
  `cli` token for them must name its policy. Anything else is a
  changeset error on `policy` naming what the user may use.

  The returned token carries its `secret`, and an `oauth` token its
  `refresh_secret` too; nothing else ever will.
  """
  @spec create_token(User.t(), map() | keyword()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def create_token(%User{id: user_id} = user, attrs) do
    attrs = Map.new(attrs)
    token = %Token{user_id: user_id}

    changeset =
      case Map.get(attrs, :kind, :cli) do
        :oauth -> token |> Token.oauth_changeset(attrs) |> put_secret(:refresh_secret)
        _cli -> Token.cli_changeset(token, attrs)
      end

    changeset
    |> validate_user_policy(user)
    |> put_secret(:secret)
    |> Repo.insert()
  end

  @doc """
  Updates a `cli` token's name or policy; the policy must be one its
  user may carry (`policies/1`). The secret cannot change; create a
  new token instead. An `oauth` token is not editable: its client is
  verified identity and its policy was chosen at consent, so the
  answer is `{:error, :oauth_token}`.
  """
  @spec update_token(Token.t(), map() | keyword()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t() | :oauth_token}
  def update_token(%Token{kind: :oauth}, _attrs), do: {:error, :oauth_token}

  def update_token(%Token{user_id: user_id} = token, attrs) do
    token
    |> Token.cli_changeset(Map.new(attrs))
    |> validate_user_policy(Repo.get!(User, user_id))
    |> Repo.update()
  end

  @doc "Deletes a token. Requests presenting its secret fail from then on."
  @spec delete_token(Token.t()) :: {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def delete_token(%Token{} = token), do: Repo.delete(token)

  @doc "Every token on the beamlet, oldest first, with users loaded."
  @spec list_tokens() :: [Token.t()]
  def list_tokens, do: Repo.all(from(t in Token, order_by: t.id, preload: :user))

  @doc "A user's tokens, oldest first, with the user loaded."
  @spec list_tokens(User.t()) :: [Token.t()]
  def list_tokens(%User{id: user_id}) do
    Repo.all(from(t in Token, where: t.user_id == ^user_id, order_by: t.id, preload: :user))
  end

  @doc "Finds a token by id, with the user loaded."
  @spec find_token(pos_integer()) :: {:ok, Token.t()} | {:error, :not_found}
  def find_token(id), do: wrap(Repo.one(from(t in Token, where: t.id == ^id, preload: :user)))

  @doc """
  Turns a presented secret into its token, with the user loaded.

  Anything that is not the secret of a stored token, including a
  deleted token's secret or a value that never was one, is
  `{:error, :unknown_token}`; the secret of an `oauth` token past its
  expiry is `{:error, :expired_token}`.
  """
  @spec authenticate(term()) :: {:ok, Token.t()} | {:error, :unknown_token | :expired_token}
  def authenticate(secret) when is_binary(secret) do
    hash = hash(secret)

    case Repo.one(from(t in Token, where: t.secret_hash == ^hash, preload: :user)) do
      nil -> {:error, :unknown_token}
      %Token{expires_at: nil} = token -> {:ok, token}
      %Token{expires_at: expires_at} = token -> expiring(token, expires_at)
    end
  end

  def authenticate(_other), do: {:error, :unknown_token}

  @doc """
  Turns a presented refresh secret into its `oauth` token, with the
  user loaded, for the token endpoint.

  Anything that is not the refresh secret of a stored token, a `cli`
  token's secret among them, is `{:error, :unknown_token}`; a refresh
  secret past `refresh_expires_at` is `{:error, :expired_token}`.
  """
  @spec authenticate_refresh(term()) ::
          {:ok, Token.t()} | {:error, :unknown_token | :expired_token}
  def authenticate_refresh(secret) when is_binary(secret) do
    hash = hash(secret)

    case Repo.one(from(t in Token, where: t.refresh_hash == ^hash, preload: :user)) do
      nil -> {:error, :unknown_token}
      %Token{refresh_expires_at: expires_at} = token -> expiring(token, expires_at)
    end
  end

  def authenticate_refresh(_other), do: {:error, :unknown_token}

  @doc """
  Rotates an `oauth` token in place: new secrets, and the expiries
  `attrs` carries (`expires_at` and `refresh_expires_at`). The row
  and its id stay, so provenance keeps pointing at the same token;
  the old secrets stop authenticating at once. The returned token
  carries the new `secret` and `refresh_secret`. A `cli` token has
  nothing to rotate and answers `{:error, :cli_token}`.
  """
  @spec rotate_token(Token.t(), map() | keyword()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t() | :cli_token}
  def rotate_token(%Token{kind: :cli}, _attrs), do: {:error, :cli_token}

  def rotate_token(%Token{kind: :oauth} = token, attrs) do
    token
    |> Token.rotate_changeset(Map.new(attrs))
    |> put_secret(:secret)
    |> put_secret(:refresh_secret)
    |> Repo.update()
  end

  # The policy is read as a field rather than a change: a cli token
  # named with no policy carries the schema's default, and a bounded
  # user who may not use it must hear so here.
  defp validate_user_policy(changeset, %User{policies: []}), do: changeset

  defp validate_user_policy(changeset, %User{name: name, policies: policies}) do
    policy = Ecto.Changeset.get_field(changeset, :policy)

    if policy in policies or Keyword.has_key?(changeset.errors, :policy) do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :policy,
        "#{policy} is not a policy #{name} may use (#{name}'s policies: #{Enum.join(policies, ", ")})"
      )
    end
  end

  defp expiring(token, expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: {:ok, token},
      else: {:error, :expired_token}
  end

  defp put_secret(changeset, field) do
    secret = generate_secret()
    hash_field = if field == :secret, do: :secret_hash, else: :refresh_hash

    changeset
    |> Ecto.Changeset.put_change(hash_field, hash(secret))
    |> Ecto.Changeset.put_change(field, secret)
  end

  defp generate_secret do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret)

  defp wrap(nil), do: {:error, :not_found}
  defp wrap(%User{} = user), do: {:ok, user}
  defp wrap(%Token{} = token), do: {:ok, token}
end
