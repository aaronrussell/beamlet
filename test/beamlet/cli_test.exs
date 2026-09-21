defmodule Beamlet.CLITest do
  use Beamlet.Case

  import ExUnit.CaptureIO

  alias Beamlet.CLI
  alias Beamlet.Users

  describe "usage" do
    test "prints usage with no arguments or --help" do
      assert {:ok, output} = with_io(fn -> CLI.main([]) end)
      assert output =~ "Usage: beamlet COMMAND"
      assert output =~ "tokens.create USER TOKEN [--policy POLICY]"
      assert output =~ "tokens.update USER TOKEN [--name NEW_NAME] [--policy POLICY]"
      assert output =~ "policies.show POLICY"

      assert {:ok, output} = with_io(fn -> CLI.main(["--help"]) end)
      assert output =~ "Usage: beamlet COMMAND"
      assert {:ok, _} = with_io(fn -> CLI.main(["users", "-h"]) end)
    end

    test "an unknown command is an error with usage on stderr" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["frobnicate"]) end)
      assert output =~ "Unknown command frobnicate."
      assert output =~ "Usage: beamlet COMMAND"
    end

    test "an unknown option is an error" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["users", "--verbose"]) end)
      assert output =~ "Unknown option --verbose."
    end

    test "wrong arguments name the command's shape" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["users.create"]) end)
      assert output =~ "beamlet users.create takes: users.create USER"

      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["tokens.delete", "alice"]) end)
      assert output =~ "beamlet tokens.delete takes: tokens.delete USER TOKEN"
    end
  end

  describe "users" do
    test "lists users as a table", %{user: alice} do
      {:ok, bob} = Users.create(name: "bob")

      assert {:ok, output} = with_io(fn -> CLI.main(["users"]) end)
      assert [header, row1, row2] = String.split(output, "\n", trim: true)
      assert header =~ ~r/^ID\s+NAME\s+LOGIN\s+CREATED$/
      assert row1 =~ ~r/^#{alice.id}\s+alice\s+no\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
      assert row2 =~ ~r/^#{bob.id}\s+bob\s+no\s+/

      {:ok, _bob} = Users.update_password(bob, "correct horse")
      assert {:ok, output} = with_io(fn -> CLI.main(["users"]) end)
      assert [_header, _row1, row2] = String.split(output, "\n", trim: true)
      assert row2 =~ ~r/^#{bob.id}\s+bob\s+yes\s+/
    end

    test "says how to create the first user when there are none", %{user: alice} do
      {:ok, _} = Users.delete(alice)

      assert {:ok, output} = with_io(fn -> CLI.main(["users"]) end)
      assert output =~ "No users yet. Create one with: beamlet users.create NAME"
    end

    test "creates a user with the password from two prompts" do
      assert {:ok, output} =
               with_io([input: "correct horse\ncorrect horse\n"], fn ->
                 CLI.main(["users.create", "bob"])
               end)

      assert output =~ "Created user bob."
      assert output =~ "Password: "
      assert output =~ "Again: "
      assert output =~ "Set password for bob."
      assert {:ok, %{name: "bob"}} = Users.authenticate_password("bob", "correct horse")
    end

    test "--no-password creates a user who cannot sign in, without prompting" do
      assert {:ok, output} =
               with_io([input: "not read\n"], fn ->
                 CLI.main(["users.create", "bob", "--no-password"])
               end)

      assert output =~ "Created user bob."
      refute output =~ "Password: "

      assert output =~
               "No password: bob cannot sign in on the web until beamlet users.update bob --password"

      assert {:ok, %{password_hash: nil}} = Users.find_by(name: "bob")
    end

    test "a bad or missing password at creation leaves the user in place and fails" do
      for {name, input, message} <- [
            {"bob", "one two three\nfour five six\n", "Passwords do not match."},
            {"carol", "short\nshort\n", "password should be at least 8 character(s)"},
            {"dave", "\n", "No password given."},
            {"erin", "", "No password given."}
          ] do
        assert {{:error, stdout}, stderr} =
                 with_io(:stderr, fn ->
                   with_io([input: input], fn -> CLI.main(["users.create", name]) end)
                 end)

        assert stdout =~ "Created user #{name}."
        assert stderr =~ message

        assert stderr =~
                 "#{name} has no password; set one with: beamlet users.update #{name} --password"

        assert {:ok, %{password_hash: nil}} = Users.find_by(name: name)
      end
    end

    test "resets a password with --password", %{user: alice} do
      assert {:ok, output} =
               with_io([input: "correct horse\ncorrect horse\n"], fn ->
                 CLI.main(["users.update", "alice", "--password"])
               end)

      assert output =~ "Password: "
      assert output =~ "Again: "
      assert output =~ "Set password for alice."
      refute output =~ "Renamed"
      assert {:ok, %{id: id}} = Users.authenticate_password("alice", "correct horse")
      assert id == alice.id
    end

    test "renames and resets the password in one command" do
      assert {:ok, output} =
               with_io([input: "correct horse\ncorrect horse\n"], fn ->
                 CLI.main(["users.update", "alice", "--name", "alicia", "--password"])
               end)

      assert output =~ "Renamed user alice to alicia."
      assert output =~ "Set password for alicia."
      assert {:ok, _user} = Users.authenticate_password("alicia", "correct horse")
    end

    test "a reset refuses a mismatch, a short password and an empty answer" do
      for {input, message} <- [
            {"one two three\nfour five six\n", "Passwords do not match."},
            {"short\nshort\n", "password should be at least 8 character(s)"},
            {"\n", "No password given."},
            {"", "No password given."}
          ] do
        assert {{:error, _stdout}, stderr} =
                 with_io(:stderr, fn ->
                   with_io([input: input], fn ->
                     CLI.main(["users.update", "alice", "--password"])
                   end)
                 end)

        assert stderr =~ message
      end

      assert {:error, :invalid_credentials} = Users.authenticate_password("alice", "short")
    end

    test "a failed rename does not go on to ask for a password" do
      {:ok, _bob} = Users.create(name: "bob")

      assert {{:error, stdout}, stderr} =
               with_io(:stderr, fn ->
                 with_io([input: "correct horse\ncorrect horse\n"], fn ->
                   CLI.main(["users.update", "alice", "--name", "bob", "--password"])
                 end)
               end)

      assert stderr =~ "name has already been taken"
      refute stdout =~ "Password: "
    end

    test "prints validation errors on create" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["users.create", "Bob"]) end)
      assert output =~ "name must be lowercase letters, digits, underscores and hyphens only"

      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["users.create", "alice"]) end)
      assert output =~ "name has already been taken"
    end

    test "renames a user with --name", %{user: alice} do
      assert {:ok, output} =
               with_io(fn -> CLI.main(["users.update", "alice", "--name", "alicia"]) end)

      assert output =~ "Renamed user alice to alicia."
      assert {:ok, %{name: "alicia"}} = Users.find(alice.id)
    end

    test "update needs --name" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["users.update", "alice"]) end)
      assert output =~ "beamlet users.update needs --name NEW_NAME or --password."
    end

    test "deletes a user and reports their tokens", %{user: alice, token: token} do
      {:ok, _} = Users.create_token(alice, name: "laptop")

      assert {:ok, output} = with_io(fn -> CLI.main(["users.delete", "alice"]) end)
      assert output =~ "Deleted user alice and 2 tokens."
      assert {:error, :not_found} = Users.find_by(name: "alice")
      assert {:error, :unknown_token} = Users.authenticate(token.secret)
    end

    test "singular token count on delete" do
      {:ok, bob} = Users.create(name: "bob")
      {:ok, _} = Users.create_token(bob, name: "phone")

      assert {:ok, output} = with_io(fn -> CLI.main(["users.delete", "bob"]) end)
      assert output =~ "Deleted user bob and 1 token."
    end

    test "an unknown user says how to list them" do
      for args <- [["users.delete", "bob"], ["users.update", "bob", "--name", "rob"]] do
        assert {:error, output} = with_io(:stderr, fn -> CLI.main(args) end)
        assert output =~ "No user named bob. Run `beamlet users` to list them."
      end
    end
  end

  describe "tokens" do
    test "lists a user's tokens with their policy", %{token: token} do
      assert {:ok, output} = with_io(fn -> CLI.main(["tokens", "alice"]) end)
      assert [header, row] = String.split(output, "\n", trim: true)
      assert header =~ ~r/^ID\s+NAME\s+POLICY\s+CREATED$/
      assert row =~ ~r/^#{token.id}\s+test\s+default\s+\d{4}-/
    end

    test "says how to create the first token when there are none", %{token: token} do
      {:ok, _} = Users.delete_token(token)

      assert {:ok, output} = with_io(fn -> CLI.main(["tokens", "alice"]) end)
      assert output =~ "alice has no tokens. Create one with: beamlet tokens.create alice NAME"
    end

    test "creates a token and prints its secret once", %{user: alice} do
      assert {:ok, output} = with_io(fn -> CLI.main(["tokens.create", "alice", "laptop"]) end)
      assert output =~ "Created token laptop for alice (policy default)."
      assert [_, secret] = Regex.run(~r/Secret \(shown once\): (\S+)/, output)

      assert {:ok, %{name: "laptop", policy: "default", user: %{id: user_id}}} =
               Users.authenticate(secret)

      assert user_id == alice.id
    end

    test "prints validation errors on create" do
      assert {:error, output} =
               with_io(:stderr, fn -> CLI.main(["tokens.create", "alice", "test"]) end)

      assert output =~ "name is already a token name for this user"

      assert {:error, output} =
               with_io(:stderr, fn -> CLI.main(["tokens.create", "alice", "My Laptop"]) end)

      assert output =~ "name must be lowercase letters"
    end

    test "renames a token with --name", %{user: alice, token: token} do
      assert {:ok, output} =
               with_io(fn -> CLI.main(["tokens.update", "alice", "test", "--name", "phone"]) end)

      assert output =~ "Updated token test for alice: name phone."
      assert {:ok, %{id: id}} = Users.find_token_by(alice, name: "phone")
      assert id == token.id
    end

    @tag policies: [restricted: [tools: [:eval]]]
    test "changes a token's policy with --policy, alone or with --name", %{user: alice} do
      assert {:ok, output} =
               with_io(fn ->
                 CLI.main(["tokens.update", "alice", "test", "--policy", "restricted"])
               end)

      assert output =~ "Updated token test for alice: policy restricted."
      assert {:ok, %{policy: "restricted"}} = Users.find_token_by(alice, name: "test")

      assert {:ok, output} =
               with_io(fn ->
                 CLI.main([
                   "tokens.update",
                   "alice",
                   "test",
                   "--name",
                   "phone",
                   "--policy",
                   "default"
                 ])
               end)

      assert output =~ "Updated token test for alice: name phone, policy default."
      assert {:ok, %{policy: "default"}} = Users.find_token_by(alice, name: "phone")
    end

    test "update needs --name or --policy" do
      assert {:error, output} =
               with_io(:stderr, fn -> CLI.main(["tokens.update", "alice", "test"]) end)

      assert output =~ "beamlet tokens.update needs --name NEW_NAME or --policy POLICY."
    end

    @tag policies: [restricted: [tools: [:eval]]]
    test "creates a token under a declared policy", %{user: alice} do
      assert {:ok, output} =
               with_io(fn ->
                 CLI.main(["tokens.create", "alice", "laptop", "--policy", "restricted"])
               end)

      assert output =~ "Created token laptop for alice (policy restricted)."
      assert {:ok, %{policy: "restricted"}} = Users.find_token_by(alice, name: "laptop")
    end

    @tag policies: [restricted: [tools: [:eval]]]
    test "an undeclared policy is the changeset's error" do
      assert {:error, output} =
               with_io(:stderr, fn ->
                 CLI.main(["tokens.create", "alice", "laptop", "--policy", "gone"])
               end)

      assert output =~
               "policy gone is not a policy on this beamlet (declared: default, restricted)"

      assert {:error, output} =
               with_io(:stderr, fn ->
                 CLI.main(["tokens.update", "alice", "test", "--policy", "gone"])
               end)

      assert output =~ "policy gone is not a policy on this beamlet"
    end

    test "deletes a token and its secret stops authenticating", %{user: alice, token: token} do
      assert {:ok, output} = with_io(fn -> CLI.main(["tokens.delete", "alice", "test"]) end)
      assert output =~ "Deleted token test for alice."
      assert Users.list_tokens(alice) == []
      assert {:error, :unknown_token} = Users.authenticate(token.secret)
    end

    test "an unknown token says how to list them" do
      for args <- [
            ["tokens.delete", "alice", "laptop"],
            ["tokens.update", "alice", "laptop", "--name", "phone"]
          ] do
        assert {:error, output} = with_io(:stderr, fn -> CLI.main(args) end)

        assert output =~
                 "alice has no token named laptop. Run `beamlet tokens alice` to list them."
      end
    end

    test "an unknown user on a token command says how to list users" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["tokens", "bob"]) end)
      assert output =~ "No user named bob. Run `beamlet users` to list them."
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
               ~r/^Policy: restricted\nTools: eval \(no define: modules cannot be added with this token\)\n/

      assert output =~ "Rules for your code:"

      assert {:ok, output} = with_io(fn -> CLI.main(["policies.show", "default"]) end)
      assert output =~ ~r/^Policy: default\nTools: define, eval\n/
    end

    test "an unknown policy says how to list them" do
      assert {:error, output} = with_io(:stderr, fn -> CLI.main(["policies.show", "nope"]) end)
      assert output =~ "No policy named nope. Run `beamlet policies` to list them."
    end
  end
end
