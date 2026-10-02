defmodule Beamlet.CLITest do
  use Beamlet.Case, shared: true

  import ExUnit.CaptureIO

  alias Beamlet.CLI
  alias Beamlet.Owner
  alias Beamlet.Repo
  alias Beamlet.Tokens

  describe "usage" do
    test "prints usage with no arguments or --help" do
      assert {:ok, output} = with_io(fn -> CLI.main([]) end)
      assert output =~ "Usage: beamlet COMMAND"
      assert output =~ "setup\n      set the owner's email and password"
      assert output =~ "tokens.create NAME [--policy POLICY]"
      assert output =~ "tokens.update ID [--name NEW_NAME] [--policy POLICY]"
      assert output =~ "policies.show POLICY"
      assert output =~ "reset"
      refute output =~ "users"
      refute output =~ "--user"

      assert {:ok, output} = with_io(fn -> CLI.main(["--help"]) end)
      assert output =~ "Usage: beamlet COMMAND"
      assert {:ok, output} = with_io(fn -> CLI.main(["tokens.create", "-h"]) end)
      assert output =~ "Usage: beamlet COMMAND"
    end

    test "an unknown command is an error with usage on stderr" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["frobnicate"]) end)
      assert output =~ "Unknown command frobnicate."
      assert output =~ "Usage: beamlet COMMAND"

      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["users.create", "bob"]) end)
      assert output =~ "Unknown command users.create."
    end

    test "a switch before the command says the command comes first" do
      assert {:error, output} =
               with_io(:stderr, fn -> CLI.main(["--policy", "x", "tokens.create", "laptop"]) end)

      assert output =~ "Unknown option --policy: the command comes first."
    end

    test "a command refuses a switch it does not take, naming its shape" do
      for {args, switch, shape} <- [
            {["tokens", "--verbose"], "--verbose", "tokens"},
            {["tokens.create", "laptop", "--name", "x"], "--name",
             "tokens.create NAME [--policy POLICY]"},
            {["tokens.create", "laptop", "--user", "bob"], "--user",
             "tokens.create NAME [--policy POLICY]"},
            {["setup", "--password"], "--password", "setup"}
          ] do
        assert {:error, output} = with_io(:stderr, fn -> CLI.main(args) end)
        command = hd(args)
        assert output =~ "beamlet #{command} does not take #{switch}; it takes: #{shape}"
      end

      assert Tokens.list() |> Enum.map(& &1.name) == ["test"]
    end

    test "a switch with no value is missing its value", %{token: token} do
      assert {:error, output} =
               with_io(:stderr, fn -> CLI.main(["tokens.create", "laptop", "--policy"]) end)

      assert output =~ "beamlet tokens.create: --policy needs a value."

      assert {:error, output} =
               with_io(:stderr, fn ->
                 CLI.main(["tokens.update", to_string(token.id), "--name"])
               end)

      assert output =~ "beamlet tokens.update: --name needs a value."
    end

    test "wrong arguments name the command's shape" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["tokens.create"]) end)
      assert output =~ "beamlet tokens.create takes: tokens.create NAME [--policy POLICY]"

      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["tokens.delete"]) end)
      assert output =~ "beamlet tokens.delete takes: tokens.delete ID"

      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["setup", "extra"]) end)
      assert output =~ "beamlet setup takes: setup"
    end
  end

  describe "setup" do
    test "the first run asks for an email and a password twice", %{user: user} do
      Repo.delete!(user)

      assert {:ok, output} =
               with_io([input: "Ada@Example.com\ncorrect horse\ncorrect horse\n"], fn ->
                 CLI.main(["setup"])
               end)

      assert output =~ "Email: "
      assert output =~ "Password: "
      assert output =~ "Again: "
      assert output =~ "Set up the owner, ada@example.com."
      assert {:ok, _user} = Owner.authenticate("ada@example.com", "correct horse")
    end

    test "the first run needs an email and a password", %{user: user} do
      Repo.delete!(user)

      for {input, message} <- [
            {"\n", "No email given."},
            {"", "No email given."},
            {"ada@example.com\n\n", "No password given."},
            {"ada@example.com\n", "No password given."},
            {"ada@example.com\none two three\nfour five six\n", "Passwords do not match."},
            {"ada@example.com\nshort\nshort\n", "password should be at least 8 character(s)"}
          ] do
        assert {{:error, _stdout}, stderr} =
                 with_io(:stderr, fn ->
                   with_io([input: input], fn -> CLI.main(["setup"]) end)
                 end)

        assert stderr =~ message
        assert {:error, :not_found} = Owner.find()
      end
    end

    test "a bad email fails before any password is asked for", %{user: user} do
      Repo.delete!(user)

      assert {{:error, stdout}, stderr} =
               with_io(:stderr, fn ->
                 with_io([input: "not an email\ncorrect horse\ncorrect horse\n"], fn ->
                   CLI.main(["setup"])
                 end)
               end)

      assert stderr =~ "email must look like name@example.com"
      refute stderr =~ "password"
      refute stdout =~ "Password: "
    end

    test "a later run offers the current email, and blanks change nothing", %{
      user: user,
      password: password
    } do
      {:ok, session} = Owner.create_session()

      assert {:ok, output} = with_io([input: "\n\n"], fn -> CLI.main(["setup"]) end)

      assert output =~ "Email [owner@example.com]: "
      assert output =~ "Password (blank keeps the current one): "
      refute output =~ "Again: "
      assert output =~ "Nothing changed."
      assert {:ok, ^user} = Owner.authenticate(user.email, password)
      assert {:ok, _user} = Owner.authenticate_session(session.secret)
    end

    test "a new email alone keeps the password and the sessions", %{password: password} do
      {:ok, session} = Owner.create_session()

      assert {:ok, output} =
               with_io([input: "new@example.com\n\n"], fn -> CLI.main(["setup"]) end)

      assert output =~ "Updated the owner: email new@example.com."
      refute output =~ "signed out"
      assert {:ok, _user} = Owner.authenticate("new@example.com", password)
      assert {:ok, _user} = Owner.authenticate_session(session.secret)
    end

    test "a new password signs every browser out", %{user: user} do
      {:ok, session} = Owner.create_session()

      assert {:ok, output} =
               with_io([input: "\nbattery staple\nbattery staple\n"], fn ->
                 CLI.main(["setup"])
               end)

      assert output =~ "Updated the owner: password."
      assert output =~ "Every browser signed in to the app is signed out."
      assert {:ok, _user} = Owner.authenticate(user.email, "battery staple")
      assert {:error, :unknown_session} = Owner.authenticate_session(session.secret)
    end

    test "a refused change on a later run changes nothing", %{user: user, password: password} do
      for {input, message} <- [
            {"\none two three\nfour five six\n", "Passwords do not match."},
            {"\nshort\nshort\n", "password should be at least 8 character(s)"},
            {"nope\n", "email must look like name@example.com"}
          ] do
        assert {{:error, _stdout}, stderr} =
                 with_io(:stderr, fn ->
                   with_io([input: input], fn -> CLI.main(["setup"]) end)
                 end)

        assert stderr =~ message
        assert {:ok, ^user} = Owner.authenticate(user.email, password)
      end
    end
  end

  describe "tokens" do
    test "lists every token with its kind and label", %{token: token} do
      {:ok, phone} = Tokens.create(name: "phone")
      {:ok, chat} = Tokens.create(oauth_attrs("https://claude.ai/client.json"))

      assert {:ok, output} = with_io(fn -> CLI.main(["tokens"]) end)
      assert [header, row1, row2, row3] = String.split(output, "\n", trim: true)
      assert header =~ ~r/^ID\s+KIND\s+LABEL\s+POLICY\s+EXPIRES\s+CREATED$/
      assert row1 =~ ~r/^#{token.id}\s+cli\s+test\s+default\s+-\s+\d{4}-/
      assert row2 =~ ~r/^#{phone.id}\s+cli\s+phone\s+default\s+-\s+\d{4}-/

      assert row3 =~
               ~r/^#{chat.id}\s+oauth\s+claude.ai\s+default\s+\d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ\s+\d{4}-/
    end

    test "says how to create the first token when there are none", %{token: token} do
      {:ok, _} = Tokens.delete(token)

      assert {:ok, output} = with_io(fn -> CLI.main(["tokens"]) end)
      assert output =~ "No tokens yet. Create one with: beamlet tokens.create NAME"
    end

    test "creates a token and prints its secret once" do
      assert {:ok, output} = with_io(fn -> CLI.main(["tokens.create", "laptop"]) end)

      assert output =~ "Created token laptop (policy default)."
      assert [_, secret] = Regex.run(~r/Secret \(shown once\): (\S+)/, output)

      assert {:ok, %{kind: :cli, name: "laptop", policy: "default"}} =
               Tokens.authenticate(secret)
    end

    test "creates a token before the owner is set up", %{user: user} do
      Repo.delete!(user)
      assert {:ok, output} = with_io(fn -> CLI.main(["tokens.create", "laptop"]) end)
      assert output =~ "Created token laptop (policy default)."
    end

    @tag policies: [restricted: [tools: [:eval]]]
    test "a token takes one --policy", %{token: token} do
      assert {:error, output} =
               with_io(:stderr, fn ->
                 CLI.main(~w(tokens.create laptop --policy default --policy restricted))
               end)

      assert output =~ "beamlet tokens.create takes one --policy POLICY."

      assert {:error, output} =
               with_io(:stderr, fn ->
                 CLI.main(
                   ["tokens.update", to_string(token.id)] ++
                     ~w(--policy default --policy restricted)
                 )
               end)

      assert output =~ "beamlet tokens.update takes one --policy POLICY."
    end

    test "prints validation errors on create" do
      assert {:error, output} =
               with_io(:stderr, fn -> CLI.main(["tokens.create", "test"]) end)

      assert output =~ "name is already a token name on this beamlet"

      assert {:error, output} =
               with_io(:stderr, fn -> CLI.main(["tokens.create", "My Laptop"]) end)

      assert output =~ "name must be lowercase letters"
    end

    test "renames a token with --name", %{token: token} do
      id = to_string(token.id)

      assert {:ok, output} =
               with_io(fn -> CLI.main(["tokens.update", id, "--name", "phone"]) end)

      assert output =~ "Updated token test (#{id}): name phone."
      assert {:ok, %{name: "phone"}} = Tokens.find(token.id)
    end

    @tag policies: [restricted: [tools: [:eval]]]
    test "changes a token's policy with --policy, alone or with --name", %{token: token} do
      id = to_string(token.id)

      assert {:ok, output} =
               with_io(fn -> CLI.main(["tokens.update", id, "--policy", "restricted"]) end)

      assert output =~ "Updated token test (#{id}): policy restricted."
      assert {:ok, %{policy: "restricted"}} = Tokens.find(token.id)

      assert {:ok, output} =
               with_io(fn ->
                 CLI.main(["tokens.update", id, "--name", "phone", "--policy", "default"])
               end)

      assert output =~ "Updated token test (#{id}): name phone, policy default."
      assert {:ok, %{name: "phone", policy: "default"}} = Tokens.find(token.id)
    end

    test "update needs --name or --policy", %{token: token} do
      assert {:error, output} =
               with_io(:stderr, fn -> CLI.main(["tokens.update", to_string(token.id)]) end)

      assert output =~ "beamlet tokens.update needs --name NEW_NAME or --policy POLICY."
    end

    test "update refuses an oauth token" do
      {:ok, chat} = Tokens.create(oauth_attrs("https://chatgpt.com/client.json"))

      assert {:error, output} =
               with_io(:stderr, fn ->
                 CLI.main(["tokens.update", to_string(chat.id), "--policy", "default"])
               end)

      assert output =~
               "Token #{chat.id} is an OAuth token (chatgpt.com): its client is verified " <>
                 "identity and its policy was chosen at consent. Delete it and connect " <>
                 "again to change either."

      assert {:ok, %{policy: "default"}} = Tokens.find(chat.id)
    end

    @tag policies: [restricted: [tools: [:eval]]]
    test "creates a token under a declared policy" do
      assert {:ok, output} =
               with_io(fn -> CLI.main(["tokens.create", "laptop", "--policy", "restricted"]) end)

      assert output =~ "Created token laptop (policy restricted)."
      assert [_, secret] = Regex.run(~r/Secret \(shown once\): (\S+)/, output)
      assert {:ok, %{policy: "restricted"}} = Tokens.authenticate(secret)
    end

    @tag policies: [restricted: [tools: [:eval]]]
    test "an undeclared policy is the changeset's error", %{token: token} do
      assert {:error, output} =
               with_io(:stderr, fn ->
                 CLI.main(["tokens.create", "laptop", "--policy", "gone"])
               end)

      assert output =~
               "policy gone is not a policy on this beamlet (declared: default, restricted)"

      assert {:error, output} =
               with_io(:stderr, fn ->
                 CLI.main(["tokens.update", to_string(token.id), "--policy", "gone"])
               end)

      assert output =~ "policy gone is not a policy on this beamlet"
    end

    test "deletes a token by id and its secret stops authenticating", %{token: token} do
      {:ok, chat} = Tokens.create(oauth_attrs("https://claude.ai/client.json"))

      assert {:ok, output} = with_io(fn -> CLI.main(["tokens.delete", to_string(token.id)]) end)
      assert output =~ "Deleted token test (#{token.id})."
      assert {:error, :unknown_token} = Tokens.authenticate(token.secret)

      assert {:ok, output} = with_io(fn -> CLI.main(["tokens.delete", to_string(chat.id)]) end)
      assert output =~ "Deleted token claude.ai (#{chat.id})."
      assert Tokens.list() == []
    end

    test "an unknown or malformed id says how to list tokens", %{token: token} do
      missing = to_string(token.id + 1)

      for args <- [["tokens.delete", missing], ["tokens.update", missing, "--name", "phone"]] do
        assert {:error, output} = with_io(:stderr, fn -> CLI.main(args) end)
        assert output =~ "No token with id #{missing}. Run `beamlet tokens` to list them."
      end

      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["tokens.delete", "test"]) end)
      assert output =~ "Token ids are numbers; run `beamlet tokens` to list them."
    end
  end

  describe "policies" do
    test "lists the default alone when none are declared" do
      assert {:ok, output} = with_io(fn -> CLI.main(["policies"]) end)
      assert String.split(output, "\n", trim: true) == ["default"]
    end

    @tag policies: [restricted: [tools: [:eval]], builder: [rules: [allow_defmacro: true]]]
    test "lists every policy by name" do
      assert {:ok, output} = with_io(fn -> CLI.main(["policies"]) end)
      assert String.split(output, "\n", trim: true) == ["builder", "default", "restricted"]
    end

    @tag policies: [restricted: [tools: [:eval]]]
    test "shows a policy as the agent reads it" do
      assert {:ok, output} = with_io(fn -> CLI.main(["policies.show", "restricted"]) end)

      assert output =~
               ~r/^Policy: restricted\nTools: eval \(not granted: define, patch\)\n/

      assert output =~ "Rules for your code:"

      assert {:ok, output} = with_io(fn -> CLI.main(["policies.show", "default"]) end)
      assert output =~ ~r/^Policy: default\nTools: define, eval, patch\n/
    end

    test "an unknown policy says how to list them" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["policies.show", "nope"]) end)
      assert output =~ "No policy named nope. Run `beamlet policies` to list them."
    end
  end

  defp oauth_attrs(client) do
    later = DateTime.add(DateTime.utc_now(:second), 3600, :second)
    %{kind: :oauth, client: client, expires_at: later, refresh_expires_at: later}
  end
end
