defmodule Beamlet.CLITest do
  use Beamlet.Case

  import ExUnit.CaptureIO

  alias Beamlet.CLI
  alias Beamlet.Users

  describe "usage" do
    test "prints usage with no arguments or --help" do
      assert {:ok, output} = with_io(fn -> CLI.main([]) end)
      assert output =~ "Usage: beamlet COMMAND"
      assert output =~ "tokens.create USER TOKEN"

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
      assert header =~ ~r/^ID\s+NAME\s+CREATED$/
      assert row1 =~ ~r/^#{alice.id}\s+alice\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
      assert row2 =~ ~r/^#{bob.id}\s+bob\s+/
    end

    test "says how to create the first user when there are none", %{user: alice} do
      {:ok, _} = Users.delete(alice)

      assert {:ok, output} = with_io(fn -> CLI.main(["users"]) end)
      assert output =~ "No users yet. Create one with: beamlet users.create NAME"
    end

    test "creates a user" do
      assert {:ok, output} = with_io(fn -> CLI.main(["users.create", "bob"]) end)
      assert output =~ "Created user bob."
      assert {:ok, %{name: "bob"}} = Users.find_by(name: "bob")
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
      assert output =~ "beamlet users.update needs --name NEW_NAME."
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
      assert output =~ "Created token laptop for alice."
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

      assert output =~ "Renamed token test to phone for alice."
      assert {:ok, %{id: id}} = Users.find_token_by(alice, name: "phone")
      assert id == token.id
    end

    test "update needs --name" do
      assert {:error, output} =
               with_io(:stderr, fn -> CLI.main(["tokens.update", "alice", "test"]) end)

      assert output =~ "beamlet tokens.update needs --name NEW_NAME."
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

    test "no policy option yet" do
      assert {:error, output} =
               with_io(:stderr, fn ->
                 CLI.main(["tokens.create", "alice", "laptop", "--policy", "strict"])
               end)

      assert output =~ "Unknown option --policy."
    end
  end
end
