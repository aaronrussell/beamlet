defmodule Beamlet.CLI do
  @moduledoc """
  The command line for managing users, tokens and policies on your
  beamlet.

      beamlet users                                 list users
      beamlet users.create USER                     create a user
      beamlet users.update USER --name NEW_NAME     rename a user
      beamlet users.delete USER                     delete a user and their tokens
      beamlet tokens USER                           list a user's tokens
      beamlet tokens.create USER TOKEN [--policy POLICY]
      beamlet tokens.update USER TOKEN [--name NEW_NAME] [--policy POLICY]
      beamlet tokens.delete USER TOKEN
      beamlet policies                              list policies
      beamlet policies.show POLICY                  show what a policy permits

  Everything addresses users and tokens by name; a token's name is
  unique per user, so every token command names the user first. A
  token runs under `default` unless `--policy` names one of the
  policies declared in config (`Beamlet.Policy`). The commands are the
  public functions of `Beamlet.Users` and `Beamlet.Policies` with
  plain text output, and `main/1` is the whole surface: it takes the
  arguments as a list, prints, and returns `:ok` or `:error`. In
  development `mix beamlet` hands it the arguments; a release ships a
  `bin/beamlet` script that does the same.

  The commands need the policies and the system database, nothing an
  agent reaches. When no beamlet is running in the VM, `main/1` starts
  that half of one (`Beamlet.start_link/1` with `only: :system`), runs
  the command and stops it again, so it works beside a beamlet running
  in another VM or with none running at all. A beamlet running in the
  same VM is used as it is.
  """

  alias Beamlet.Policies
  alias Beamlet.Policy
  alias Beamlet.Users

  @commands [
    {"users", "", "list users"},
    {"users.create", "USER", "create a user"},
    {"users.update", "USER --name NEW_NAME", "rename a user"},
    {"users.delete", "USER", "delete a user and their tokens"},
    {"tokens", "USER", "list a user's tokens"},
    {"tokens.create", "USER TOKEN [--policy POLICY]", "create a token, printing its secret once"},
    {"tokens.update", "USER TOKEN [--name NEW_NAME] [--policy POLICY]",
     "rename a token or change its policy"},
    {"tokens.delete", "USER TOKEN", "delete a token"},
    {"policies", "", "list policies"},
    {"policies.show", "POLICY", "show what a policy permits"}
  ]

  @shapes Enum.map(@commands, fn {command, args, description} ->
            {String.trim("#{command} #{args}"), description}
          end)
  @width @shapes |> Enum.map(fn {shape, _} -> String.length(shape) end) |> Enum.max()

  @usage """
  Usage: beamlet COMMAND [ARGS]

  Manage users, tokens and policies on your beamlet. Names are
  lowercase letters, digits, underscores and hyphens.

  #{Enum.map_join(@shapes, "\n", fn {shape, description} -> "  " <> String.pad_trailing(shape, @width + 2) <> description end)}
  """

  @doc """
  Runs one command from its arguments, printing the outcome.

  Usage goes to stdout, errors to stderr. Returns `:ok` when the
  command ran and `:error` when it did not, for the caller to turn
  into an exit status.
  """
  @spec main([String.t()]) :: :ok | :error
  def main(argv) when is_list(argv) do
    parsed =
      OptionParser.parse(argv,
        strict: [name: :string, policy: :string, help: :boolean],
        aliases: [h: :help]
      )

    case parsed do
      {_opts, _args, [{switch, _value} | _rest]} ->
        fail("Unknown option #{switch}.\n\n" <> @usage)

      {opts, args, []} ->
        if Keyword.get(opts, :help, false) or args == [] do
          puts(@usage)
        else
          [command | args] = args
          run(command, args, opts)
        end
    end
  end

  defp run("users", [], _opts), do: with_beamlet(&list_users/0)
  defp run("users.create", [name], _opts), do: with_beamlet(fn -> create_user(name) end)

  defp run("users.update", [name], opts) do
    with_name("users.update", opts, fn new_name ->
      with_beamlet(fn -> update_user(name, new_name) end)
    end)
  end

  defp run("users.delete", [name], _opts), do: with_beamlet(fn -> delete_user(name) end)
  defp run("tokens", [user], _opts), do: with_beamlet(fn -> list_tokens(user) end)

  defp run("tokens.create", [user, name], opts) do
    with_beamlet(fn -> create_token(user, name, Keyword.take(opts, [:policy])) end)
  end

  defp run("tokens.update", [user, name], opts) do
    case Keyword.take(opts, [:name, :policy]) do
      [] -> fail("beamlet tokens.update needs --name NEW_NAME or --policy POLICY.")
      attrs -> with_beamlet(fn -> update_token(user, name, attrs) end)
    end
  end

  defp run("tokens.delete", [user, name], _opts) do
    with_beamlet(fn -> delete_token(user, name) end)
  end

  defp run("policies", [], _opts), do: with_beamlet(&list_policies/0)
  defp run("policies.show", [name], _opts), do: with_beamlet(fn -> show_policy(name) end)

  defp run(command, _args, _opts) do
    case List.keyfind(@commands, command, 0) do
      {^command, args, _description} ->
        fail("beamlet #{command} takes: " <> String.trim("#{command} #{args}"))

      nil ->
        fail("Unknown command #{command}.\n\n" <> @usage)
    end
  end

  defp list_users do
    case Users.list() do
      [] ->
        puts("No users yet. Create one with: beamlet users.create NAME")

      users ->
        table(["ID", "NAME", "CREATED"], Enum.map(users, &[&1.id, &1.name, &1.inserted_at]))
    end
  end

  defp create_user(name) do
    case Users.create(name: name) do
      {:ok, user} -> puts("Created user #{user.name}.")
      {:error, changeset} -> fail(changeset)
    end
  end

  defp update_user(name, new_name) do
    with_user(name, fn user ->
      case Users.update(user, name: new_name) do
        {:ok, updated} -> puts("Renamed user #{user.name} to #{updated.name}.")
        {:error, changeset} -> fail(changeset)
      end
    end)
  end

  defp delete_user(name) do
    with_user(name, fn user ->
      count = user |> Users.list_tokens() |> length()

      case Users.delete(user) do
        {:ok, _user} -> puts("Deleted user #{user.name} and #{plural(count, "token")}.")
        {:error, changeset} -> fail(changeset)
      end
    end)
  end

  defp list_tokens(user_name) do
    with_user(user_name, fn user ->
      case Users.list_tokens(user) do
        [] ->
          puts(
            "#{user.name} has no tokens. Create one with: beamlet tokens.create #{user.name} NAME"
          )

        tokens ->
          table(
            ["ID", "NAME", "POLICY", "CREATED"],
            Enum.map(tokens, &[&1.id, &1.name, &1.policy, &1.inserted_at])
          )
      end
    end)
  end

  defp create_token(user_name, name, attrs) do
    with_user(user_name, fn user ->
      case Users.create_token(user, [name: name] ++ attrs) do
        {:ok, token} ->
          puts("Created token #{token.name} for #{user.name} (policy #{token.policy}).")
          puts("Secret (shown once): #{token.secret}")

        {:error, changeset} ->
          fail(changeset)
      end
    end)
  end

  defp update_token(user_name, name, attrs) do
    with_token(user_name, name, fn user, token ->
      case Users.update_token(token, attrs) do
        {:ok, _updated} ->
          changes = Enum.map_join(attrs, ", ", fn {field, value} -> "#{field} #{value}" end)
          puts("Updated token #{token.name} for #{user.name}: #{changes}.")

        {:error, changeset} ->
          fail(changeset)
      end
    end)
  end

  defp delete_token(user_name, name) do
    with_token(user_name, name, fn user, token ->
      case Users.delete_token(token) do
        {:ok, _token} -> puts("Deleted token #{token.name} for #{user.name}.")
        {:error, changeset} -> fail(changeset)
      end
    end)
  end

  defp list_policies, do: Policies.names() |> Enum.join("\n") |> puts()

  defp show_policy(name) do
    case Policies.fetch(name) do
      {:ok, policy} ->
        puts(Policy.render(policy))

      {:error, :not_found} ->
        fail("No policy named #{name}. Run `beamlet policies` to list them.")
    end
  end

  defp with_user(name, fun) do
    case Users.find_by(name: name) do
      {:ok, user} -> fun.(user)
      {:error, :not_found} -> fail("No user named #{name}. Run `beamlet users` to list them.")
    end
  end

  defp with_token(user_name, name, fun) do
    with_user(user_name, fn user ->
      case Users.find_token_by(user, name: name) do
        {:ok, token} ->
          fun.(user, token)

        {:error, :not_found} ->
          fail(
            "#{user.name} has no token named #{name}. Run `beamlet tokens #{user.name}` to list them."
          )
      end
    end)
  end

  defp with_name(command, opts, fun) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> fun.(name)
      :error -> fail("beamlet #{command} needs --name NEW_NAME.")
    end
  end

  defp with_beamlet(fun) do
    if Process.whereis(Beamlet), do: fun.(), else: start_and_run(fun)
  end

  # Beamlet has no application of its own, so starting it here starts
  # only its dependencies, which a bare VM has not. The beamlet then
  # links to this process, so a boot that fails on a bad policy would
  # take the command down with it instead of printing the error;
  # trapping turns that exit into a message.
  defp start_and_run(fun) do
    {:ok, _apps} = Application.ensure_all_started(:beamlet)
    trapping? = Process.flag(:trap_exit, true)

    try do
      case Beamlet.start_link(only: :system) do
        {:ok, pid} ->
          try do
            fun.()
          after
            Supervisor.stop(pid)
          end

        {:error, {:shutdown, {:failed_to_start_child, _child, {error, _stack}}}}
        when is_exception(error) ->
          fail(Exception.message(error))
      end
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  defp table(headers, rows) do
    rows = [headers | Enum.map(rows, fn row -> Enum.map(row, &to_string/1) end)]

    widths =
      Enum.zip_with(rows, fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    rows
    |> Enum.map_join("\n", fn row ->
      row |> Enum.zip_with(widths, &String.pad_trailing/2) |> Enum.join("  ") |> String.trim()
    end)
    |> puts()
  end

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp puts(message) do
    IO.puts(message)
    :ok
  end

  defp fail(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join("\n")
    |> fail()
  end

  defp fail(message) when is_binary(message) do
    IO.puts(:stderr, message)
    :error
  end
end
