defmodule Beamlet.CLI do
  @moduledoc """
  The command line for managing users, tokens and policies on your
  beamlet.

      beamlet users                                 list users
      beamlet users.create USER [--no-password] [--policy POLICY ...]
      beamlet users.update USER [--name NEW_NAME] [--password] [--policy POLICY ... | --all-policies]
      beamlet users.delete USER                     delete a user and their tokens
      beamlet tokens [--user USER]                  list tokens, all or one user's
      beamlet tokens.create NAME --user USER [--policy POLICY]
      beamlet tokens.update ID [--name NEW_NAME] [--policy POLICY]
      beamlet tokens.delete ID
      beamlet policies                              list policies
      beamlet policies.show POLICY                  show what a policy permits

  Users are addressed by name and tokens by the id the listing
  prints. The tokens created here are `cli` tokens, named by the
  operator; `oauth` tokens arrive when a person connects a chat client
  and consents, so they are listed and deleted here but never created
  or edited (`Beamlet.Token`). A token runs under `default` unless
  `--policy` names one of the policies declared in config
  (`Beamlet.Policy`).

  A user's `--policy`, repeatable, bounds which policies their tokens
  may carry; `users.update --policy` replaces the whole list and
  `--all-policies` clears it. A user with no list, which is what
  `users` shows as `all`, may use every declared policy. For a user
  whose list lacks `default`, `tokens.create` needs `--policy`, since
  there is no default to fall back on. Narrowing a list does not
  touch existing tokens: the command counts those now outside it, and
  the beamlet refuses them on their next request until they are
  updated or deleted.

  A password is prompted for, never taken as an argument, so it stays
  out of the shell history: `users.create` asks for one unless
  `--no-password` says the user will not sign in on the web, which is
  all a user whose only credentials are tokens needs;
  `users.update --password` sets or resets one. Piped input is read
  as the answer, one line per prompt. The commands are the public
  functions of `Beamlet.Users` and `Beamlet.Policies` with plain text
  output, and `main/1` is the whole surface: it takes the arguments
  as a list, prints, and returns `:ok` or `:error`. In development
  `mix beamlet` hands it the arguments; a release ships a
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
  alias Beamlet.Token
  alias Beamlet.Users

  @commands [
    {"users", "", "list users"},
    {"users.create", "USER [--no-password] [--policy POLICY ...]",
     "create a user, prompting for a password"},
    {"users.update", "USER [--name NEW_NAME] [--password] [--policy POLICY ... | --all-policies]",
     "rename a user, reset their password or set their policies"},
    {"users.delete", "USER", "delete a user and their tokens"},
    {"tokens", "[--user USER]", "list tokens, all or one user's"},
    {"tokens.create", "NAME --user USER [--policy POLICY]",
     "create a CLI token, printing its secret once"},
    {"tokens.update", "ID [--name NEW_NAME] [--policy POLICY]",
     "rename a CLI token or change its policy"},
    {"tokens.delete", "ID", "delete a token"},
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
  lowercase letters, digits, underscores and hyphens; tokens are
  addressed by the id `beamlet tokens` prints.

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
        strict: [
          name: :string,
          password: :boolean,
          policy: :keep,
          all_policies: :boolean,
          user: :string,
          help: :boolean
        ],
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

  defp run("users.create", [name], opts) do
    policies = Keyword.get_values(opts, :policy)
    with_beamlet(fn -> create_user(name, policies, Keyword.get(opts, :password, true)) end)
  end

  defp run("users.update", [name], opts) do
    case user_changes(opts) do
      {:ok, []} ->
        fail(
          "beamlet users.update needs --name NEW_NAME, --password, --policy POLICY " <>
            "or --all-policies."
        )

      {:ok, changes} ->
        with_beamlet(fn -> update_user(name, changes) end)

      {:error, message} ->
        fail(message)
    end
  end

  defp run("users.delete", [name], _opts), do: with_beamlet(fn -> delete_user(name) end)

  defp run("tokens", [], opts) do
    with_beamlet(fn -> list_tokens(Keyword.get(opts, :user)) end)
  end

  defp run("tokens.create", [name], opts) do
    with {:ok, user} <- Keyword.fetch(opts, :user),
         {:ok, attrs} <- one_policy("tokens.create", opts) do
      with_beamlet(fn -> create_token(user, name, attrs) end)
    else
      :error -> fail("beamlet tokens.create needs --user USER.")
      {:error, message} -> fail(message)
    end
  end

  defp run("tokens.update", [id], opts) do
    case one_policy("tokens.update", opts) do
      {:ok, policy} ->
        case Keyword.take(opts, [:name]) ++ policy do
          [] -> fail("beamlet tokens.update needs --name NEW_NAME or --policy POLICY.")
          attrs -> with_beamlet(fn -> update_token(id, attrs) end)
        end

      {:error, message} ->
        fail(message)
    end
  end

  defp run("tokens.delete", [id], _opts), do: with_beamlet(fn -> delete_token(id) end)

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

  # A user's --policy is repeatable and a token's is not, so the
  # parser keeps every value and the token commands take exactly one.
  defp one_policy(command, opts) do
    case Keyword.get_values(opts, :policy) do
      [] -> {:ok, []}
      [policy] -> {:ok, [policy: policy]}
      _many -> {:error, "beamlet #{command} takes one --policy POLICY."}
    end
  end

  defp user_changes(opts) do
    changes = Keyword.take(opts, [:name, :password])

    case {Keyword.get_values(opts, :policy), Keyword.get(opts, :all_policies, false)} do
      {[], false} ->
        {:ok, changes}

      {[], true} ->
        {:ok, changes ++ [policies: []]}

      {policies, false} ->
        {:ok, changes ++ [policies: policies]}

      {_policies, true} ->
        {:error, "beamlet users.update takes --policy or --all-policies, not both."}
    end
  end

  defp list_users do
    case Users.list() do
      [] ->
        puts("No users yet. Create one with: beamlet users.create NAME")

      users ->
        table(
          ["ID", "NAME", "LOGIN", "POLICIES", "CREATED"],
          Enum.map(users, &[&1.id, &1.name, login(&1), policies(&1, ","), &1.inserted_at])
        )
    end
  end

  # The user is created before the password is asked for, so a bad
  # name fails before anyone types anything; a password that then
  # fails leaves the user in place and says how to set one.
  defp create_user(name, policies, password?) do
    case Users.create(name: name, policies: policies) do
      {:ok, %{policies: []} = user} ->
        puts("Created user #{user.name}.")
        password_at_creation(user, password?)

      {:ok, user} ->
        puts("Created user #{user.name} (policies #{policies(user, ", ")}).")
        password_at_creation(user, password?)

      {:error, changeset} ->
        fail(changeset)
    end
  end

  defp password_at_creation(user, password?) do
    cond do
      not password? -> no_password(user)
      set_password(user) == :ok -> :ok
      true -> fail("#{user.name} has no password; set one with: " <> update_hint(user))
    end
  end

  defp no_password(user) do
    puts("No password: #{user.name} cannot sign in on the web until " <> update_hint(user))
  end

  defp update_hint(user), do: "beamlet users.update #{user.name} --password"

  defp update_user(name, changes) do
    with_user(name, fn user ->
      with {:ok, user} <- update_attrs(user, Keyword.take(changes, [:name, :policies])) do
        if Keyword.get(changes, :password, false), do: set_password(user), else: :ok
      end
    end)
  end

  defp update_attrs(user, []), do: {:ok, user}

  defp update_attrs(user, attrs) do
    case Users.update(user, attrs) do
      {:ok, updated} ->
        if updated.name != user.name, do: puts("Renamed user #{user.name} to #{updated.name}.")
        if Keyword.has_key?(attrs, :policies), do: report_policies(updated)
        {:ok, updated}

      {:error, changeset} ->
        fail(changeset)
    end
  end

  # Existing tokens are left alone; the plug refuses any now outside
  # the list, so the operator hears here which ones those are.
  defp report_policies(user) do
    puts("Set policies for #{user.name}: #{policies(user, ", ")}.")
    allowed = Users.policies(user)

    case user |> Users.list_tokens() |> Enum.reject(&(&1.policy in allowed)) do
      [] ->
        :ok

      outside ->
        labels = Enum.map_join(outside, ", ", &"#{Token.label(&1)} (#{&1.policy})")

        puts(
          "#{plural(length(outside), "token")} outside the list, refused until updated " <>
            "or deleted: #{labels}."
        )
    end
  end

  defp set_password(user) do
    case read_password("Password: ") do
      {:ok, ""} -> fail("No password given.")
      {:error, message} -> fail(message)
      {:ok, password} -> confirm_and_set(user, password)
    end
  end

  defp confirm_and_set(user, password) do
    with {:ok, ^password} <- read_password("Again: "),
         {:ok, _user} <- Users.update_password(user, password) do
      puts("Set password for #{user.name}.")
    else
      {:ok, _other} -> fail("Passwords do not match.")
      {:error, message} when is_binary(message) -> fail(message)
      {:error, changeset} -> fail(changeset)
    end
  end

  # A password read from a terminal must not echo, and the terminal
  # under -noshell (mix, elixir -e, a release's eval) stays in cooked
  # mode where the OS echoes every line; OTP 28's raw no-shell mode
  # turns that off for the read. That only applies when this process
  # reads from the terminal's own io server: piped input, or a test's
  # captured io, reads a plain line, which nothing echoes anyway.
  defp read_password(prompt) do
    if Process.group_leader() == Process.whereis(:user) and
         :shell.start_interactive({:noshell, :raw}) == :ok do
      IO.write(prompt)
      password = :io.get_password()
      :shell.start_interactive({:noshell, :cooked})
      IO.write("\n")
      password_line(password)
    else
      line = IO.gets(prompt)
      IO.write("\n")
      password_line(line)
    end
  end

  defp password_line(line) when is_binary(line), do: {:ok, String.trim_trailing(line, "\n")}
  defp password_line(line) when is_list(line), do: password_line(List.to_string(line))
  defp password_line(_eof_or_error), do: {:error, "No password given."}

  defp delete_user(name) do
    with_user(name, fn user ->
      count = user |> Users.list_tokens() |> length()

      case Users.delete(user) do
        {:ok, _user} -> puts("Deleted user #{user.name} and #{plural(count, "token")}.")
        {:error, changeset} -> fail(changeset)
      end
    end)
  end

  defp list_tokens(nil) do
    case Users.list_tokens() do
      [] -> puts("No tokens yet. Create one with: beamlet tokens.create NAME --user USER")
      tokens -> token_table(tokens)
    end
  end

  defp list_tokens(user_name) do
    with_user(user_name, fn user ->
      case Users.list_tokens(user) do
        [] ->
          puts(
            "#{user.name} has no tokens. Create one with: " <>
              "beamlet tokens.create NAME --user #{user.name}"
          )

        tokens ->
          token_table(tokens)
      end
    end)
  end

  defp token_table(tokens) do
    table(
      ["ID", "KIND", "USER", "LABEL", "POLICY", "EXPIRES", "CREATED"],
      Enum.map(
        tokens,
        &[
          &1.id,
          &1.kind,
          &1.user.name,
          Token.label(&1),
          &1.policy,
          &1.expires_at || "-",
          &1.inserted_at
        ]
      )
    )
  end

  defp create_token(user_name, name, attrs) do
    with_user(user_name, fn user ->
      if attrs == [] and "default" not in Users.policies(user) do
        fail(
          "#{user.name}'s tokens must carry one of: #{policies(user, ", ")}. " <>
            "Pick one with --policy POLICY."
        )
      else
        case Users.create_token(user, [name: name] ++ attrs) do
          {:ok, token} ->
            puts("Created token #{token.name} for #{user.name} (policy #{token.policy}).")
            puts("Secret (shown once): #{token.secret}")

          {:error, changeset} ->
            fail(changeset)
        end
      end
    end)
  end

  defp update_token(id, attrs) do
    with_token(id, fn token ->
      case Users.update_token(token, attrs) do
        {:ok, _updated} ->
          changes = Enum.map_join(attrs, ", ", fn {field, value} -> "#{field} #{value}" end)

          puts(
            "Updated token #{Token.label(token)} (#{token.id}) for #{token.user.name}: #{changes}."
          )

        {:error, :oauth_token} ->
          fail(
            "Token #{token.id} is an OAuth token (#{Token.label(token)}): its client is " <>
              "verified identity and its policy was chosen at consent. Delete it and " <>
              "connect again to change either."
          )

        {:error, changeset} ->
          fail(changeset)
      end
    end)
  end

  defp delete_token(id) do
    with_token(id, fn token ->
      case Users.delete_token(token) do
        {:ok, _token} ->
          puts("Deleted token #{Token.label(token)} (#{token.id}) for #{token.user.name}.")

        {:error, changeset} ->
          fail(changeset)
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

  defp with_token(id, fun) do
    with {number, ""} <- Integer.parse(id),
         {:ok, token} <- Users.find_token(number) do
      fun.(token)
    else
      {:error, :not_found} -> fail("No token with id #{id}. Run `beamlet tokens` to list them.")
      _not_a_number -> fail("Token ids are numbers; run `beamlet tokens` to list them.")
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

  defp login(%{password_hash: nil}), do: "no"
  defp login(_user), do: "yes"

  defp policies(%{policies: []}, _separator), do: "all"
  defp policies(%{policies: policies}, separator), do: Enum.join(policies, separator)

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
