defmodule Beamlet.UsersTest do
  use Beamlet.Case

  alias Beamlet.Token
  alias Beamlet.User
  alias Beamlet.Users

  describe "create/1" do
    test "creates a user with a valid name" do
      assert {:ok, %User{id: id, name: "bob"}} = Users.create(%{name: "bob"})
      assert is_integer(id)
      assert {:ok, %User{name: "a-b_1"}} = Users.create(name: "a-b_1")
    end

    test "rejects names outside lowercase letters, digits, underscore and hyphen" do
      for bad <- ["Alice", "al ice", "al.ice", "al@ice", "al\nice"] do
        assert {:error, changeset} = Users.create(name: bad)
        assert %{name: [message]} = errors_on(changeset)
        assert message =~ "lowercase letters, digits, underscores and hyphens"
      end
    end

    test "rejects an empty or missing name" do
      assert {:error, changeset} = Users.create(name: "")
      assert %{name: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = Users.create(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a name longer than 64 characters" do
      assert {:error, changeset} = Users.create(name: String.duplicate("a", 65))
      assert %{name: [message]} = errors_on(changeset)
      assert message =~ "at most 64"
      assert {:ok, _} = Users.create(name: String.duplicate("a", 64))
    end

    test "rejects a duplicate name" do
      assert {:ok, _} = Users.create(name: "bob")
      assert {:error, changeset} = Users.create(name: "bob")
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "update/2" do
    test "renames a user and keeps the id" do
      {:ok, %User{id: id} = user} = Users.create(name: "bob")
      assert {:ok, %User{id: ^id, name: "bob2"}} = Users.update(user, name: "bob2")
      assert {:ok, %User{name: "bob2"}} = Users.find(id)
    end

    test "applies the same name rules" do
      {:ok, user} = Users.create(name: "carol")
      {:ok, _} = Users.create(name: "bob")
      assert {:error, changeset} = Users.update(user, name: "Bob")
      assert %{name: [_]} = errors_on(changeset)
      assert {:error, changeset} = Users.update(user, name: "bob")
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "delete/1" do
    test "deletes the user and their tokens", %{user: user, token: token} do
      {:ok, _} = Users.create_token(user, name: "laptop")

      assert {:ok, %User{}} = Users.delete(user)
      assert {:error, :not_found} = Users.find(user.id)
      assert {:error, :unknown_token} = Users.authenticate(token.secret)
      assert Beamlet.Repo.aggregate(Token, :count) == 0
    end
  end

  describe "list/0" do
    test "lists users oldest first", %{user: alice} do
      assert [^alice] = Users.list()
      {:ok, bob} = Users.create(name: "bob")
      assert [^alice, ^bob] = Users.list()
    end
  end

  describe "find/1 and find_by/1" do
    test "find by id" do
      {:ok, user} = Users.create(name: "bob")
      assert {:ok, ^user} = Users.find(user.id)
      assert {:error, :not_found} = Users.find(user.id + 1)
    end

    test "find_by clauses" do
      {:ok, user} = Users.create(name: "bob")
      assert {:ok, ^user} = Users.find_by(name: "bob")
      assert {:error, :not_found} = Users.find_by(name: "carol")
    end
  end

  describe "create_token/2" do
    test "returns the secret once and stores only its hash", %{user: user} do
      assert {:ok, %Token{id: id, name: "laptop", secret: secret, secret_hash: hash}} =
               Users.create_token(user, name: "laptop")

      assert is_binary(secret)
      assert byte_size(hash) == 32
      assert hash == :crypto.hash(:sha256, secret)

      assert [_test, %Token{id: ^id, secret: nil, secret_hash: ^hash}] = Users.list_tokens(user)
    end

    test "secrets are URL-safe and unique", %{user: user} do
      {:ok, a} = Users.create_token(user, name: "a")
      {:ok, b} = Users.create_token(user, name: "b")
      assert a.secret != b.secret
      assert a.secret =~ ~r/^[A-Za-z0-9_-]{43}$/
    end

    test "defaults the policy and accepts a named one", %{user: user} do
      assert {:ok, %Token{policy: "default"}} = Users.create_token(user, name: "laptop")

      assert {:ok, %Token{policy: "restricted"}} =
               Users.create_token(user, name: "phone", policy: "restricted")
    end

    test "requires a name under the name rules", %{user: user} do
      assert {:error, changeset} = Users.create_token(user, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = Users.create_token(user, name: "My Laptop")
      assert %{name: [message]} = errors_on(changeset)
      assert message =~ "lowercase letters"
    end

    test "an empty policy means the default one", %{user: user} do
      assert {:ok, %Token{policy: "default"}} =
               Users.create_token(user, name: "laptop", policy: "")

      assert {:error, changeset} = Users.create_token(user, name: "phone", policy: nil)
      assert %{policy: ["can't be blank"]} = errors_on(changeset)
    end

    test "names are unique per user, not per beamlet", %{user: user} do
      {:ok, bob} = Users.create(name: "bob")
      assert {:ok, _} = Users.create_token(user, name: "laptop")
      assert {:ok, _} = Users.create_token(bob, name: "laptop")

      assert {:error, changeset} = Users.create_token(user, name: "laptop")
      assert %{name: ["is already a token name for this user"]} = errors_on(changeset)
    end
  end

  describe "update_token/2" do
    test "changes the policy or name and keeps the secret", %{user: user} do
      {:ok, %Token{id: id, secret: secret} = token} = Users.create_token(user, name: "laptop")

      assert {:ok, %Token{id: ^id, policy: "restricted", name: "work"}} =
               Users.update_token(token, policy: "restricted", name: "work")

      assert {:ok, %Token{id: ^id, policy: "restricted"}} = Users.authenticate(secret)
    end
  end

  describe "delete_token/1" do
    test "removes the token and its secret stops authenticating", %{user: user, token: token} do
      assert {:ok, %Token{}} = Users.delete_token(token)
      assert Users.list_tokens(user) == []
      assert {:error, :unknown_token} = Users.authenticate(token.secret)
      assert {:ok, _} = Users.find(user.id)
    end
  end

  describe "list_tokens/1" do
    test "lists a user's tokens oldest first", %{user: user, token: %Token{id: t}} do
      {:ok, bob} = Users.create(name: "bob")
      {:ok, %Token{id: b}} = Users.create_token(user, name: "b")
      {:ok, %Token{id: a}} = Users.create_token(user, name: "a")
      {:ok, _} = Users.create_token(bob, name: "phone")

      assert [%Token{id: ^t}, %Token{id: ^b}, %Token{id: ^a}] = Users.list_tokens(user)
    end
  end

  describe "find_token_by/2" do
    test "finds a user's token by name", %{user: user, token: %Token{id: id}} do
      assert {:ok, %Token{id: ^id, secret: nil}} = Users.find_token_by(user, name: "test")
      assert {:error, :not_found} = Users.find_token_by(user, name: "laptop")
    end

    test "does not see another user's token of the same name", %{user: user} do
      {:ok, bob} = Users.create(name: "bob")
      {:ok, phone} = Users.create_token(bob, name: "phone")

      assert {:error, :not_found} = Users.find_token_by(user, name: "phone")
      assert {:ok, %Token{id: id}} = Users.find_token_by(bob, name: "phone")
      assert id == phone.id
    end
  end

  describe "authenticate/1" do
    test "turns a secret into its token with the user loaded", %{user: user} do
      {:ok, %Token{id: id, secret: secret}} = Users.create_token(user, name: "laptop")
      user_id = user.id

      assert {:ok, %Token{id: ^id, secret: nil, user: %User{id: ^user_id, name: "alice"}}} =
               Users.authenticate(secret)
    end

    test "two tokens for one user authenticate to the same user", %{user: user} do
      {:ok, laptop} = Users.create_token(user, name: "laptop")
      {:ok, phone} = Users.create_token(user, name: "phone", policy: "restricted")

      assert {:ok, %Token{name: "laptop", policy: "default", user: %User{name: "alice"}}} =
               Users.authenticate(laptop.secret)

      assert {:ok, %Token{name: "phone", policy: "restricted", user: %User{name: "alice"}}} =
               Users.authenticate(phone.secret)
    end

    test "rejects anything that is not a stored secret", %{user: user} do
      {:ok, token} = Users.create_token(user, name: "laptop")
      assert {:error, :unknown_token} = Users.authenticate("")
      assert {:error, :unknown_token} = Users.authenticate("garbage")
      assert {:error, :unknown_token} = Users.authenticate(token.secret <> "x")
      assert {:error, :unknown_token} = Users.authenticate(token.secret_hash)
      assert {:error, :unknown_token} = Users.authenticate(nil)
      assert {:error, :unknown_token} = Users.authenticate(42)
    end
  end
end
