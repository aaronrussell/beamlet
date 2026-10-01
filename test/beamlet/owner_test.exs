defmodule Beamlet.OwnerTest do
  use Beamlet.Case

  alias Beamlet.Owner
  alias Beamlet.Repo
  alias Beamlet.Session
  alias Beamlet.User

  describe "find/0" do
    test "is the owner", %{user: user} do
      assert {:ok, ^user} = Owner.find()
    end

    test "is not found before the first setup", %{user: user} do
      Repo.delete!(user)
      assert {:error, :not_found} = Owner.find()
    end
  end

  describe "create/1" do
    setup %{user: user} do
      Repo.delete!(user)
      :ok
    end

    test "stores the email and a hash of the password, never the password" do
      assert {:ok, %User{id: 1, email: "ada@example.com", password: nil, password_hash: hash}} =
               Owner.create(email: "ada@example.com", password: "correct horse")

      assert String.starts_with?(hash, "$pbkdf2-sha512$")
      refute hash =~ "correct horse"
      assert {:ok, %User{password: nil, password_hash: ^hash}} = Owner.find()
    end

    test "requires an email and a password" do
      assert {:error, changeset} = Owner.create(%{})
      assert %{email: ["can't be blank"], password: ["can't be blank"]} = errors_on(changeset)
    end

    test "stores the email trimmed and lowercased" do
      assert {:ok, %User{email: "ada@example.com"}} =
               Owner.create(email: "  Ada@Example.COM\n", password: "correct horse")
    end

    test "refuses an email that does not look like one" do
      for bad <- ["ada", "ada@", "@example.com", "ada@exa mple.com", "a@b@c"] do
        assert {:error, changeset} = Owner.create(email: bad, password: "correct horse")
        assert %{email: ["must look like name@example.com"]} = errors_on(changeset)
      end

      long = String.duplicate("a", 150) <> "@example.com"
      assert {:error, changeset} = Owner.create(email: long, password: "correct horse")
      assert %{email: ["should be at most 160 character(s)"]} = errors_on(changeset)
    end

    test "takes a password of at least 8 characters and at most 128 bytes" do
      for {password, message} <- [
            {"seven77", "should be at least 8 character(s)"},
            {"éééé", "should be at least 8 character(s)"},
            {String.duplicate("a", 129), "should be at most 128 byte(s)"},
            {String.duplicate("é", 65), "should be at most 128 byte(s)"}
          ] do
        assert {:error, changeset} = Owner.create(email: "ada@example.com", password: password)
        assert %{password: [^message]} = errors_on(changeset)
      end

      assert {:ok, _user} =
               Owner.create(email: "ada@example.com", password: String.duplicate("é", 64))
    end

    test "a beamlet has one user" do
      {:ok, _user} = Owner.create(email: "ada@example.com", password: "correct horse")

      assert {:error, changeset} =
               Owner.create(email: "bob@example.com", password: "correct battery")

      assert %{id: ["is taken: a beamlet has one user; update it instead"]} =
               errors_on(changeset)

      assert {:ok, %User{email: "ada@example.com"}} = Owner.find()
    end
  end

  describe "update/2" do
    test "changes the email and keeps the password and the sessions", %{
      user: user,
      password: password
    } do
      {:ok, session} = Owner.create_session()

      assert {:ok, %User{email: "new@example.com", password_hash: hash}} =
               Owner.update(user, email: "New@Example.com")

      assert hash == user.password_hash
      assert {:ok, _user} = Owner.authenticate("new@example.com", password)
      assert {:ok, _user} = Owner.authenticate_session(session.secret)
    end

    test "a new password replaces the old and ends every session", %{
      user: user,
      password: password
    } do
      {:ok, first} = Owner.create_session()
      {:ok, second} = Owner.create_session()

      assert {:ok, _user} = Owner.update(user, password: "battery staple")

      assert {:ok, _user} = Owner.authenticate(user.email, "battery staple")
      assert {:error, :invalid_credentials} = Owner.authenticate(user.email, password)
      assert {:error, :unknown_session} = Owner.authenticate_session(first.secret)
      assert {:error, :unknown_session} = Owner.authenticate_session(second.secret)
    end

    test "a refused change ends nothing", %{user: user} do
      {:ok, session} = Owner.create_session()

      assert {:error, changeset} = Owner.update(user, email: "nope", password: "battery staple")
      assert %{email: [_message]} = errors_on(changeset)
      assert {:error, _changeset} = Owner.update(user, password: "short")
      assert {:ok, _user} = Owner.authenticate_session(session.secret)
    end
  end

  describe "authenticate/2" do
    test "finds the owner by email and password, in any case", %{user: user, password: password} do
      assert {:ok, ^user} = Owner.authenticate("owner@example.com", password)
      assert {:ok, ^user} = Owner.authenticate(" Owner@Example.com ", password)
    end

    test "fails the same way for a wrong email, a wrong password and anything else", %{
      password: password
    } do
      for {email, given} <- [
            {"owner@example.com", "wrong password"},
            {"other@example.com", password},
            {"owner@example.com", ""},
            {nil, password},
            {"owner@example.com", nil}
          ] do
        assert {:error, :invalid_credentials} = Owner.authenticate(email, given)
      end
    end

    test "fails the same way before the first setup", %{user: user, password: password} do
      Repo.delete!(user)
      assert {:error, :invalid_credentials} = Owner.authenticate(user.email, password)
    end

    test "refuses a password longer than the owner can have", %{user: user} do
      longest = String.duplicate("a", 128)
      {:ok, user} = Owner.update(user, password: longest)

      assert {:ok, _user} = Owner.authenticate(user.email, longest)
      assert {:error, :invalid_credentials} = Owner.authenticate(user.email, longest <> "a")

      assert {:error, :invalid_credentials} =
               Owner.authenticate(user.email, String.duplicate("a", 1_000_000))
    end
  end

  describe "sessions" do
    test "a session's secret is returned once and only its hash is stored" do
      assert {:ok, %Session{id: id, secret: secret, secret_hash: hash}} = Owner.create_session()

      assert secret =~ ~r/^[A-Za-z0-9_-]{43}$/
      assert hash == :crypto.hash(:sha256, secret)
      assert %Session{secret: nil, secret_hash: ^hash} = Repo.get!(Session, id)

      {:ok, other} = Owner.create_session()
      refute other.secret == secret
    end

    test "a session's secret turns back into the owner", %{user: user} do
      {:ok, session} = Owner.create_session()
      assert {:ok, ^user} = Owner.authenticate_session(session.secret)
    end

    test "anything that is not a stored session's secret is unknown", %{user: user} do
      {:ok, session} = Owner.create_session()

      for secret <- ["not-a-secret", session.secret_hash, nil, 42] do
        assert {:error, :unknown_session} = Owner.authenticate_session(secret)
      end

      Repo.delete!(user)
      assert {:error, :unknown_session} = Owner.authenticate_session(session.secret)
    end

    test "deleting a session signs that browser out and leaves the others" do
      {:ok, first} = Owner.create_session()
      {:ok, second} = Owner.create_session()

      assert :ok = Owner.delete_session(first.secret)
      assert :ok = Owner.delete_session(first.secret)
      assert :ok = Owner.delete_session(nil)
      assert {:error, :unknown_session} = Owner.authenticate_session(first.secret)
      assert {:ok, _user} = Owner.authenticate_session(second.secret)
    end
  end
end
