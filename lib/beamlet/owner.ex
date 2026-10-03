defmodule Beamlet.Owner do
  @moduledoc """
  The beamlet's owner: the one user, their password, and the browsers
  they are signed in on.

  A beamlet belongs to one person. `beamlet setup` creates the user on
  its first run and updates it on every one after; there is no second
  user to create and no way to delete the one there is. Tokens are the
  owner's delegations to their clients and live in `Beamlet.Tokens`,
  apart from this row.

      {:ok, user} = Beamlet.Owner.create(%{email: "ada@example.com", password: "correct horse"})
      {:ok, user} = Beamlet.Owner.authenticate("ada@example.com", "correct horse")

  A sign-in creates a session whose secret the browser holds:
  `create_session/0` shows it once, `authenticate_session/1` turns it
  back into the user, and `delete_session/1` signs that browser out.
  Setting a new password ends every session. A web sign-in is the
  user on a request and nothing more: no token and no policy, since a
  browser authors no code.

  An embedding host calls `create/1` and `update/2` in place of
  `beamlet setup`. Agent code never reaches these functions.
  """

  import Ecto.Query

  alias Beamlet.Repo
  alias Beamlet.Secret
  alias Beamlet.Session
  alias Beamlet.User

  @typedoc """
  The owner: `email` and the password's hash.

  `password` is virtual and never loaded.
  """
  @type user :: %User{}

  @typedoc """
  A browser signed in as the owner.

  `secret` is virtual, set only on the struct `create_session/0`
  returns.
  """
  @type session :: %Session{}

  @doc "The owner, or `{:error, :not_found}` before the first `beamlet setup`."
  @spec find() :: {:ok, user()} | {:error, :not_found}
  def find do
    case Repo.one(User) do
      nil -> {:error, :not_found}
      %User{} = user -> {:ok, user}
    end
  end

  @doc """
  Creates the owner from an email and a password.

  A beamlet has one, so a second create fails on `id` and the answer
  is `update/2`.
  """
  @spec create(map() | keyword()) :: {:ok, user()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert()
  end

  @doc """
  Updates the owner's email, password or both.

  A new password ends every session, so a browser signed in with the
  old one is signed out; a new email keeps them.
  """
  @spec update(user(), map() | keyword()) :: {:ok, user()} | {:error, Ecto.Changeset.t()}
  def update(%User{} = user, attrs) do
    changeset = User.changeset(user, Map.new(attrs))

    Repo.transact(fn ->
      with {:ok, updated} <- Repo.update(changeset) do
        if Ecto.Changeset.changed?(changeset, :password_hash), do: Repo.delete_all(Session)
        {:ok, updated}
      end
    end)
  end

  @doc """
  Turns an email and password into the owner, for the sign-in form.

  A wrong email, a wrong password and a beamlet with no owner yet all
  fail the same way, `{:error, :invalid_credentials}`, and take the
  same time, so the reply reveals nothing about which. A password
  longer than the owner can have fails the same way without being
  hashed, since hashing cost grows with its length.
  """
  @spec authenticate(term(), term()) :: {:ok, user()} | {:error, :invalid_credentials}
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    email = User.normalize_email(email)

    with true <- byte_size(password) <= User.max_password_bytes(),
         {:ok, %User{email: ^email} = user} <- find() do
      if Pbkdf2.verify_pass(password, user.password_hash),
        do: {:ok, user},
        else: {:error, :invalid_credentials}
    else
      _other ->
        Pbkdf2.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  def authenticate(_email, _password) do
    Pbkdf2.no_user_verify()
    {:error, :invalid_credentials}
  end

  @doc """
  Creates a session, for a web sign-in.

  The returned session carries its `secret`; nothing else ever will.
  """
  @spec create_session() :: {:ok, session()} | {:error, Ecto.Changeset.t()}
  def create_session do
    secret = Secret.generate()

    %Session{secret: secret}
    |> Ecto.Changeset.change(secret_hash: Secret.hash(secret))
    |> Repo.insert()
  end

  @doc """
  Turns a browser's session secret into the owner.

  Anything that is not the secret of a stored session, including one
  that was signed out, is `{:error, :unknown_session}`.
  """
  @spec authenticate_session(term()) :: {:ok, user()} | {:error, :unknown_session}
  def authenticate_session(secret) when is_binary(secret) do
    hash = Secret.hash(secret)

    with true <- Repo.exists?(from(s in Session, where: s.secret_hash == ^hash)),
         {:ok, user} <- find() do
      {:ok, user}
    else
      _other -> {:error, :unknown_session}
    end
  end

  def authenticate_session(_other), do: {:error, :unknown_session}

  @doc "Deletes the session a secret names, signing its browser out; a secret that names none is a no-op."
  @spec delete_session(term()) :: :ok
  def delete_session(secret) when is_binary(secret) do
    hash = Secret.hash(secret)
    Repo.delete_all(from(s in Session, where: s.secret_hash == ^hash))
    :ok
  end

  def delete_session(_other), do: :ok
end
