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

    test "reserves beamlet for the system principal" do
      assert {:error, changeset} = Users.create(name: "beamlet")
      assert %{name: ["is reserved for the beamlet itself"]} = errors_on(changeset)
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
      assert {:ok, %Token{id: id, kind: :cli, name: "laptop", secret: secret, secret_hash: hash}} =
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

    @tag policies: [restricted: []]
    test "defaults the policy and accepts a declared one", %{user: user} do
      assert {:ok, %Token{policy: "default"}} = Users.create_token(user, name: "laptop")

      assert {:ok, %Token{policy: "restricted"}} =
               Users.create_token(user, name: "phone", policy: "restricted")
    end

    @tag policies: [restricted: []]
    test "refuses a policy the beamlet does not declare", %{user: user} do
      assert {:error, changeset} = Users.create_token(user, name: "phone", policy: "gone")

      assert %{policy: ["gone is not a policy on this beamlet (declared: default, restricted)"]} =
               errors_on(changeset)

      {:ok, token} = Users.create_token(user, name: "laptop")
      assert {:error, changeset} = Users.update_token(token, policy: "gone")
      assert %{policy: [_message]} = errors_on(changeset)
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

    test "a cli token never expires and has no refresh secret", %{user: user} do
      assert {:ok, %Token{expires_at: nil, refresh_secret: nil, refresh_hash: nil}} =
               Users.create_token(user, name: "laptop")
    end

    test "an oauth token takes the client id and both expiries, and returns two secrets", %{
      user: user
    } do
      attrs = oauth_attrs("https://claude.ai/.well-known/client.json")

      assert {:ok,
              %Token{
                id: id,
                kind: :oauth,
                name: nil,
                client: "https://claude.ai/.well-known/client.json",
                secret: secret,
                secret_hash: hash,
                refresh_secret: refresh,
                refresh_hash: refresh_hash
              } = token} = Users.create_token(user, attrs)

      assert token.expires_at == attrs.expires_at
      assert token.refresh_expires_at == attrs.refresh_expires_at
      assert secret != refresh
      assert hash == :crypto.hash(:sha256, secret)
      assert refresh_hash == :crypto.hash(:sha256, refresh)

      assert {:ok, %Token{id: ^id, secret: nil, refresh_secret: nil}} = Users.find_token(id)
      assert {:ok, %Token{id: ^id}} = Users.authenticate(secret)
    end

    test "an oauth token requires the client and both expiries", %{user: user} do
      assert {:error, changeset} = Users.create_token(user, kind: :oauth)

      assert %{
               client: ["can't be blank"],
               expires_at: ["can't be blank"],
               refresh_expires_at: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "two oauth tokens for the same client may coexist", %{user: user} do
      attrs = oauth_attrs("https://claude.ai/.well-known/client.json")
      assert {:ok, _} = Users.create_token(user, attrs)
      assert {:ok, _} = Users.create_token(user, attrs)
    end
  end

  describe "label/1" do
    test "is the name of a cli token and the host of an oauth token's client", %{user: user} do
      {:ok, cli} = Users.create_token(user, name: "laptop")
      {:ok, oauth} = Users.create_token(user, oauth_attrs("https://claude.ai/.well-known/c.json"))
      {:ok, odd} = Users.create_token(user, oauth_attrs("not a url"))

      assert Token.label(cli) == "laptop"
      assert Token.label(oauth) == "claude.ai"
      assert Token.label(odd) == "not a url"
    end
  end

  describe "update_token/2" do
    @tag policies: [restricted: []]
    test "changes the policy or name and keeps the secret", %{user: user} do
      {:ok, %Token{id: id, secret: secret} = token} = Users.create_token(user, name: "laptop")

      assert {:ok, %Token{id: ^id, policy: "restricted", name: "work"}} =
               Users.update_token(token, policy: "restricted", name: "work")

      assert {:ok, %Token{id: ^id, policy: "restricted"}} = Users.authenticate(secret)
    end

    test "refuses an oauth token", %{user: user} do
      {:ok, token} = Users.create_token(user, oauth_attrs("https://claude.ai/c.json"))
      assert {:error, :oauth_token} = Users.update_token(token, policy: "default")
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

  describe "list_tokens/0 and list_tokens/1" do
    test "lists a user's tokens oldest first, with the user loaded", %{
      user: user,
      token: %Token{id: t}
    } do
      {:ok, bob} = Users.create(name: "bob")
      {:ok, %Token{id: b}} = Users.create_token(user, name: "b")
      {:ok, %Token{id: a}} = Users.create_token(user, name: "a")
      {:ok, _} = Users.create_token(bob, name: "phone")

      assert [%Token{id: ^t, user: %User{name: "alice"}}, %Token{id: ^b}, %Token{id: ^a}] =
               Users.list_tokens(user)
    end

    test "lists every token on the beamlet oldest first", %{user: user, token: %Token{id: t}} do
      {:ok, bob} = Users.create(name: "bob")
      {:ok, %Token{id: p}} = Users.create_token(bob, name: "phone")
      {:ok, %Token{id: a}} = Users.create_token(user, name: "a")

      assert [
               %Token{id: ^t, user: %User{name: "alice"}},
               %Token{id: ^p, user: %User{name: "bob"}},
               %Token{id: ^a}
             ] = Users.list_tokens()
    end
  end

  describe "find_token/1" do
    test "finds a token by id with the user loaded", %{token: %Token{id: id}} do
      assert {:ok, %Token{id: ^id, secret: nil, user: %User{name: "alice"}}} =
               Users.find_token(id)

      assert {:error, :not_found} = Users.find_token(id + 1)
    end
  end

  describe "authenticate/1" do
    test "turns a secret into its token with the user loaded", %{user: user} do
      {:ok, %Token{id: id, secret: secret}} = Users.create_token(user, name: "laptop")
      user_id = user.id

      assert {:ok, %Token{id: ^id, secret: nil, user: %User{id: ^user_id, name: "alice"}}} =
               Users.authenticate(secret)
    end

    @tag policies: [restricted: []]
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

    test "an oauth token past its expiry is expired, and its refresh secret is not a secret", %{
      user: user
    } do
      attrs = oauth_attrs("https://claude.ai/c.json")
      {:ok, live} = Users.create_token(user, attrs)
      {:ok, %Token{id: id}} = Users.authenticate(live.secret)
      assert id == live.id
      assert {:error, :unknown_token} = Users.authenticate(live.refresh_secret)

      past = DateTime.add(DateTime.utc_now(), -1, :second)
      {:ok, expired} = Users.create_token(user, %{attrs | expires_at: past})
      assert {:error, :expired_token} = Users.authenticate(expired.secret)
    end
  end

  describe "update_password/2" do
    test "stores a hash and never the password", %{user: user} do
      assert {:ok, %User{password: nil, password_hash: hash}} =
               Users.update_password(user, "correct horse")

      assert String.starts_with?(hash, "$pbkdf2-sha512$")
      refute hash =~ "correct horse"
      assert {:ok, %User{password: nil, password_hash: ^hash}} = Users.find(user.id)
    end

    test "takes 8 to 128 characters", %{user: user} do
      assert {:error, changeset} = Users.update_password(user, "seven77")
      assert %{password: ["should be at least 8 character(s)"]} = errors_on(changeset)

      assert {:error, changeset} = Users.update_password(user, String.duplicate("a", 129))
      assert %{password: ["should be at most 128 character(s)"]} = errors_on(changeset)

      assert {:error, changeset} = Users.update_password(user, "")
      assert %{password: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, _user} = Users.update_password(user, "eight888")
      assert {:ok, _user} = Users.update_password(user, String.duplicate("a", 128))
    end

    test "replaces an earlier password", %{user: user} do
      {:ok, _user} = Users.update_password(user, "first one")
      {:ok, _user} = Users.update_password(user, "second one")
      assert {:ok, _user} = Users.authenticate_password("alice", "second one")
      assert {:error, :invalid_credentials} = Users.authenticate_password("alice", "first one")
    end
  end

  describe "authenticate_password/2" do
    test "finds the user by name and password", %{user: user} do
      {:ok, _user} = Users.update_password(user, "correct horse")
      user_id = user.id

      assert {:ok, %User{id: ^user_id, name: "alice", password: nil}} =
               Users.authenticate_password("alice", "correct horse")
    end

    test "fails the same way for a wrong password, an unknown name and no password", %{
      user: user
    } do
      {:ok, _user} = Users.update_password(user, "correct horse")
      {:ok, _bob} = Users.create(name: "bob")

      assert {:error, :invalid_credentials} = Users.authenticate_password("alice", "wrong")

      assert {:error, :invalid_credentials} =
               Users.authenticate_password("carol", "correct horse")

      assert {:error, :invalid_credentials} = Users.authenticate_password("bob", "correct horse")
      assert {:error, :invalid_credentials} = Users.authenticate_password("bob", "")
      assert {:error, :invalid_credentials} = Users.authenticate_password(nil, "correct horse")
      assert {:error, :invalid_credentials} = Users.authenticate_password("alice", nil)
    end
  end

  defp oauth_attrs(client) do
    now = DateTime.utc_now(:second)

    %{
      kind: :oauth,
      client: client,
      expires_at: DateTime.add(now, 3600, :second),
      refresh_expires_at: DateTime.add(now, 7 * 86_400, :second)
    }
  end
end
