defmodule Beamlet.TokensTest do
  use Beamlet.Case, shared: true

  alias Beamlet.Token
  alias Beamlet.Tokens

  describe "create/1" do
    test "returns the secret once and stores only its hash" do
      assert {:ok, %Token{id: id, kind: :cli, name: "laptop", secret: secret, secret_hash: hash}} =
               Tokens.create(name: "laptop")

      assert is_binary(secret)
      assert byte_size(hash) == 32
      assert hash == :crypto.hash(:sha256, secret)

      assert [_test, %Token{id: ^id, secret: nil, secret_hash: ^hash}] = Tokens.list()
    end

    test "secrets are URL-safe and unique" do
      {:ok, a} = Tokens.create(name: "a")
      {:ok, b} = Tokens.create(name: "b")
      assert a.secret != b.secret
      assert a.secret =~ ~r/^[A-Za-z0-9_-]{43}$/
    end

    @tag policies: [restricted: []]
    test "defaults the policy and accepts a declared one" do
      assert {:ok, %Token{policy: "default"}} = Tokens.create(name: "laptop")

      assert {:ok, %Token{policy: "restricted"}} =
               Tokens.create(name: "phone", policy: "restricted")
    end

    @tag policies: [restricted: []]
    test "refuses a policy the beamlet does not declare" do
      assert {:error, changeset} = Tokens.create(name: "phone", policy: "gone")

      assert %{policy: ["gone is not a policy on this beamlet (declared: default, restricted)"]} =
               errors_on(changeset)

      {:ok, token} = Tokens.create(name: "laptop")
      assert {:error, changeset} = Tokens.update(token, policy: "gone")
      assert %{policy: [_message]} = errors_on(changeset)
    end

    test "requires a name under the name rules" do
      assert {:error, changeset} = Tokens.create(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = Tokens.create(name: "My Laptop")
      assert %{name: [message]} = errors_on(changeset)
      assert message =~ "lowercase letters"
    end

    test "reserves beamlet for the system principal" do
      assert {:error, changeset} = Tokens.create(name: "beamlet")
      assert %{name: ["is reserved for the beamlet itself"]} = errors_on(changeset)
    end

    test "an empty policy means the default one" do
      assert {:ok, %Token{policy: "default"}} =
               Tokens.create(name: "laptop", policy: "")

      assert {:error, changeset} = Tokens.create(name: "phone", policy: nil)
      assert %{policy: ["can't be blank"]} = errors_on(changeset)
    end

    test "names are unique across the beamlet" do
      assert {:ok, laptop} = Tokens.create(name: "laptop")

      assert {:error, changeset} = Tokens.create(name: "laptop")
      assert %{name: ["is already a token name on this beamlet"]} = errors_on(changeset)

      {:ok, phone} = Tokens.create(name: "phone")
      assert {:error, changeset} = Tokens.update(phone, name: "laptop")
      assert %{name: ["is already a token name on this beamlet"]} = errors_on(changeset)

      {:ok, _} = Tokens.delete(laptop)
      assert {:ok, _} = Tokens.create(name: "laptop")
    end

    test "a cli token never expires and has no refresh secret" do
      assert {:ok, %Token{expires_at: nil, refresh_secret: nil, refresh_hash: nil}} =
               Tokens.create(name: "laptop")
    end

    test "an oauth token takes the client id and both expiries, and returns two secrets" do
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
              } = token} = Tokens.create(attrs)

      assert token.expires_at == attrs.expires_at
      assert token.refresh_expires_at == attrs.refresh_expires_at
      assert secret != refresh
      assert hash == :crypto.hash(:sha256, secret)
      assert refresh_hash == :crypto.hash(:sha256, refresh)

      assert {:ok, %Token{id: ^id, secret: nil, refresh_secret: nil}} = Tokens.find(id)
      assert {:ok, %Token{id: ^id}} = Tokens.authenticate(secret)
    end

    test "an oauth token requires the client and both expiries" do
      assert {:error, changeset} = Tokens.create(kind: :oauth)

      assert %{
               client: ["can't be blank"],
               expires_at: ["can't be blank"],
               refresh_expires_at: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "two oauth tokens for the same client may coexist" do
      attrs = oauth_attrs("https://claude.ai/.well-known/client.json")
      assert {:ok, _} = Tokens.create(attrs)
      assert {:ok, _} = Tokens.create(attrs)
    end
  end

  describe "label/1" do
    test "is the name of a cli token and the host of an oauth token's client" do
      {:ok, cli} = Tokens.create(name: "laptop")
      {:ok, oauth} = Tokens.create(oauth_attrs("https://claude.ai/.well-known/c.json"))
      {:ok, odd} = Tokens.create(oauth_attrs("not a url"))

      assert Token.label(cli) == "laptop"
      assert Token.label(oauth) == "claude.ai"
      assert Token.label(odd) == "not a url"
    end
  end

  describe "update/2" do
    @tag policies: [restricted: []]
    test "changes the policy or name and keeps the secret" do
      {:ok, %Token{id: id, secret: secret} = token} = Tokens.create(name: "laptop")

      assert {:ok, %Token{id: ^id, policy: "restricted", name: "work"}} =
               Tokens.update(token, policy: "restricted", name: "work")

      assert {:ok, %Token{id: ^id, policy: "restricted"}} = Tokens.authenticate(secret)
    end

    test "refuses an oauth token" do
      {:ok, token} = Tokens.create(oauth_attrs("https://claude.ai/c.json"))
      assert {:error, :oauth_token} = Tokens.update(token, policy: "default")
    end
  end

  describe "delete/1" do
    test "removes the token and its secret stops authenticating", %{token: token} do
      assert {:ok, %Token{}} = Tokens.delete(token)
      assert Tokens.list() == []
      assert {:error, :unknown_token} = Tokens.authenticate(token.secret)
    end
  end

  describe "list/0" do
    test "lists every token on the beamlet oldest first", %{token: %Token{id: t}} do
      {:ok, %Token{id: p}} = Tokens.create(name: "phone")
      {:ok, %Token{id: a}} = Tokens.create(name: "a")
      {:ok, %Token{id: o}} = Tokens.create(oauth_attrs("https://claude.ai/c.json"))

      assert [%Token{id: ^t}, %Token{id: ^p}, %Token{id: ^a}, %Token{id: ^o}] = Tokens.list()
    end
  end

  describe "find/1" do
    test "finds a token by id", %{token: %Token{id: id}} do
      assert {:ok, %Token{id: ^id, name: "test", secret: nil}} = Tokens.find(id)

      assert {:error, :not_found} = Tokens.find(id + 1)
    end
  end

  describe "authenticate/1" do
    @tag policies: [restricted: []]
    test "turns a secret into its token" do
      {:ok, %Token{id: id, secret: secret}} = Tokens.create(name: "laptop")
      {:ok, phone} = Tokens.create(name: "phone", policy: "restricted")

      assert {:ok, %Token{id: ^id, name: "laptop", policy: "default", secret: nil}} =
               Tokens.authenticate(secret)

      assert {:ok, %Token{name: "phone", policy: "restricted"}} =
               Tokens.authenticate(phone.secret)
    end

    test "rejects anything that is not a stored secret" do
      {:ok, token} = Tokens.create(name: "laptop")
      assert {:error, :unknown_token} = Tokens.authenticate("")
      assert {:error, :unknown_token} = Tokens.authenticate("garbage")
      assert {:error, :unknown_token} = Tokens.authenticate(token.secret <> "x")
      assert {:error, :unknown_token} = Tokens.authenticate(token.secret_hash)
      assert {:error, :unknown_token} = Tokens.authenticate(nil)
      assert {:error, :unknown_token} = Tokens.authenticate(42)
    end

    test "an oauth token past its expiry is expired, and its refresh secret is not a secret" do
      attrs = oauth_attrs("https://claude.ai/c.json")
      {:ok, live} = Tokens.create(attrs)
      {:ok, %Token{id: id}} = Tokens.authenticate(live.secret)
      assert id == live.id
      assert {:error, :unknown_token} = Tokens.authenticate(live.refresh_secret)

      past = DateTime.add(DateTime.utc_now(), -1, :second)
      {:ok, expired} = Tokens.create(%{attrs | expires_at: past})
      assert {:error, :expired_token} = Tokens.authenticate(expired.secret)
    end
  end

  describe "authenticate_refresh/1" do
    test "turns a refresh secret into its oauth token" do
      {:ok, token} = Tokens.create(oauth_attrs("https://claude.ai/c.json"))

      assert {:ok, %Token{id: id, kind: :oauth}} =
               Tokens.authenticate_refresh(token.refresh_secret)

      assert id == token.id
    end

    test "rejects an access secret, a cli secret and anything else", %{token: cli} do
      {:ok, token} = Tokens.create(oauth_attrs("https://claude.ai/c.json"))

      for secret <- [token.secret, cli.secret, "nonsense", nil] do
        assert {:error, :unknown_token} = Tokens.authenticate_refresh(secret)
      end
    end

    test "a refresh secret past its expiry is expired" do
      attrs = oauth_attrs("https://claude.ai/c.json")
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      {:ok, token} = Tokens.create(%{attrs | refresh_expires_at: past})
      assert {:error, :expired_token} = Tokens.authenticate_refresh(token.refresh_secret)
    end
  end

  describe "rotate/2" do
    test "keeps the row and replaces both secrets and both expiries" do
      {:ok, token} = Tokens.create(oauth_attrs("https://claude.ai/c.json"))
      later = DateTime.add(DateTime.utc_now(:second), 7200, :second)

      {:ok, rotated} = Tokens.rotate(token, expires_at: later, refresh_expires_at: later)

      assert rotated.id == token.id
      assert rotated.client == token.client
      assert rotated.secret != token.secret
      assert rotated.refresh_secret != token.refresh_secret
      assert rotated.expires_at == later
      assert rotated.refresh_expires_at == later
      assert {:ok, %Token{id: id}} = Tokens.authenticate(rotated.secret)
      assert id == token.id
      assert {:error, :unknown_token} = Tokens.authenticate(token.secret)
      assert {:error, :unknown_token} = Tokens.authenticate_refresh(token.refresh_secret)
    end

    test "a refresh secret rotates once, however many loaded it" do
      {:ok, token} = Tokens.create(oauth_attrs("https://claude.ai/c.json"))
      {:ok, first} = Tokens.authenticate_refresh(token.refresh_secret)
      {:ok, second} = Tokens.authenticate_refresh(token.refresh_secret)
      later = DateTime.add(DateTime.utc_now(:second), 7200, :second)
      attrs = [expires_at: later, refresh_expires_at: later]

      assert {:ok, rotated} = Tokens.rotate(first, attrs)
      assert {:error, :unknown_token} = Tokens.rotate(second, attrs)

      assert {:ok, %Token{id: id}} = Tokens.authenticate_refresh(rotated.refresh_secret)
      assert id == token.id
      assert {:ok, %Token{id: ^id}} = Tokens.authenticate(rotated.secret)
    end

    test "requires both expiries and refuses a cli token", %{token: cli} do
      {:ok, token} = Tokens.create(oauth_attrs("https://claude.ai/c.json"))
      attrs = %{expires_at: nil, refresh_expires_at: nil}
      assert {:error, %Ecto.Changeset{} = changeset} = Tokens.rotate(token, attrs)
      assert %{expires_at: _, refresh_expires_at: _} = errors_on(changeset)
      assert {:error, :cli_token} = Tokens.rotate(cli, %{})
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
