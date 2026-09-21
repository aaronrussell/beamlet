defmodule Beamlet.Users do
  @moduledoc """
  Users and their tokens: the operator's store for who may work on a
  beamlet and with what credentials.

  A user is a durable name (`Beamlet.User`); a token is a credential
  belonging to one user, carrying the policy its requests run under
  (`Beamlet.Token`). Creating a token is the one moment its secret is
  visible:

      {:ok, user} = Beamlet.Users.create(%{name: "alice"})
      {:ok, token} = Beamlet.Users.create_token(user, %{name: "laptop"})
      token.secret
      #=> "wJalrXUtnFEMI_K7MDENG_bPxRfiCYEXAMPLEKEY_q0"

  The secret is what a client sends as its bearer credential. Only its
  hash is stored, so `authenticate/1` is how a request finds its token
  and user, and a lost secret means a new token. Policy attaches to
  the token, not the user: a token names one and has `default` when
  it names none, and the name must be a policy the beamlet declares
  (`Beamlet.Policies`).

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

  @doc "Updates a user. Only the name changes today; the id, and everything keyed on it, stays."
  @spec update(User.t(), map() | keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update(%User{} = user, attrs) do
    user
    |> User.changeset(Map.new(attrs))
    |> Repo.update()
  end

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
  Creates a token for a user from `name` and an optional `policy`.

  The returned token carries its `secret`; nothing else ever will.
  """
  @spec create_token(User.t(), map() | keyword()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def create_token(%User{id: user_id}, attrs) do
    secret = generate_secret()

    %Token{user_id: user_id}
    |> Token.changeset(Map.new(attrs))
    |> Ecto.Changeset.put_change(:secret_hash, hash(secret))
    |> Ecto.Changeset.put_change(:secret, secret)
    |> Repo.insert()
  end

  @doc "Updates a token's name or policy. The secret cannot change; create a new token instead."
  @spec update_token(Token.t(), map() | keyword()) ::
          {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def update_token(%Token{} = token, attrs) do
    token
    |> Token.changeset(Map.new(attrs))
    |> Repo.update()
  end

  @doc "Deletes a token. Requests presenting its secret fail from then on."
  @spec delete_token(Token.t()) :: {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def delete_token(%Token{} = token), do: Repo.delete(token)

  @doc "A user's tokens, oldest first."
  @spec list_tokens(User.t()) :: [Token.t()]
  def list_tokens(%User{id: user_id}) do
    Repo.all(from(t in Token, where: t.user_id == ^user_id, order_by: t.id))
  end

  @doc "Finds the one token of a user matching the clauses, such as `name: \"laptop\"`."
  @spec find_token_by(User.t(), keyword()) :: {:ok, Token.t()} | {:error, :not_found}
  def find_token_by(%User{id: user_id}, clauses) do
    wrap(Repo.get_by(Token, [user_id: user_id] ++ clauses))
  end

  @doc """
  Turns a presented secret into its token, with the user loaded.

  Anything that is not the secret of a stored token, including a
  deleted token's secret or a value that never was one, is
  `{:error, :unknown_token}`.
  """
  @spec authenticate(term()) :: {:ok, Token.t()} | {:error, :unknown_token}
  def authenticate(secret) when is_binary(secret) do
    hash = hash(secret)

    case Repo.one(from(t in Token, where: t.secret_hash == ^hash, preload: :user)) do
      nil -> {:error, :unknown_token}
      token -> {:ok, token}
    end
  end

  def authenticate(_other), do: {:error, :unknown_token}

  defp generate_secret do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret)

  defp wrap(nil), do: {:error, :not_found}
  defp wrap(%User{} = user), do: {:ok, user}
  defp wrap(%Token{} = token), do: {:ok, token}
end
