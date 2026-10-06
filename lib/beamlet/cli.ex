defmodule Beamlet.CLI do
  @commands [
    {"setup", "", "set the owner's email and password", []},
    {"tokens", "", "list tokens", []},
    {"tokens.create", "<NAME> [--policy POLICY]", "create a CLI token, printing its secret once",
     [policy: :keep]},
    {"tokens.update", "<ID> [--name NEW_NAME] [--policy POLICY]",
     "rename a CLI token or change its policy", [name: :string, policy: :keep]},
    {"tokens.delete", "<ID>", "delete a token", []},
    {"policies", "", "list policies", []},
    {"policies.show", "<POLICY>", "show what a policy permits", []},
    {"reset", "", "wipe everything agents built: routes, agent database, code, files", []}
  ]

  @command_table Enum.map_join(@commands, "\n", fn {command, args, description, _switches} ->
                   "  #{String.trim("#{command} #{args}")}\n      #{description}"
                 end)

  @usage """
  Usage: beamlet COMMAND [ARGS]

  Set up the owner and manage tokens and policies on your beamlet.
  Token names are lowercase letters, digits, underscores and hyphens;
  tokens are addressed by the id `beamlet tokens` prints.

  #{@command_table}
  """

  @details %{
    "setup" => """
    Sets the owner's email and password, which sign in to the app at
    `/beamlet`. Run it again to change either. A blank password keeps
    the current one, and a new password signs every browser out.
    """,
    "tokens" => """
    Lists every token with its id, policy and expiry. Tokens created
    here show their name. Tokens a chat client received through OAuth
    show the client's host.
    """,
    "tokens.create" => """
    Creates a token and prints its secret. The secret is shown only
    this once, so copy it into your MCP client now. The token gets
    the `default` policy unless `--policy` names another.
    """,
    "tokens.update" => """
    Renames a token or changes its policy, from the client's next
    request. OAuth tokens cannot be changed. Delete one and connect
    the client again instead.
    """,
    "tokens.delete" => """
    Deletes a token of either kind. A client using it is refused from
    its next request.
    """,
    "policies" => """
    Lists the policies you can give a token: `default`, and any
    declared in config.
    """,
    "policies.show" => """
    Shows what a policy allows: its tools, its rules, and the modules
    it denies or grants only in part.
    """,
    "reset" => """
    Deletes everything agents have built: the routes, the agent
    database, the code dir with its history, and the files dir. The
    owner, the tokens and your `config.exs` are kept. Restart the
    beamlet afterwards, since until then it keeps running what it had
    loaded.
    """
  }

  @command_sections Enum.map_join(@commands, "\n", fn {command, args, _description, _switches} ->
                      "### `beamlet #{String.trim("#{command} #{args}")}`\n\n" <>
                        Map.fetch!(@details, command)
                    end)

  @moduledoc """
  The command line for setting up the owner and managing tokens and
  policies on your beamlet.

  ## Commands

  #{@command_sections}
  """

  alias Beamlet.Config
  alias Beamlet.Owner
  alias Beamlet.Policies
  alias Beamlet.Policy
  alias Beamlet.Routes
  alias Beamlet.Token
  alias Beamlet.Tokens
  alias Beamlet.User

  @doc """
  Runs one command from its arguments, printing the outcome.

  Usage goes to stdout, errors to stderr. Returns `:ok` when the
  command ran and `:error` when it did not, for the caller to turn
  into an exit status.
  """
  @spec main([String.t()]) :: :ok | :error
  def main(argv) when is_list(argv) do
    case argv do
      [] ->
        puts(@usage)

      [help | _rest] when help in ["--help", "-h"] ->
        puts(@usage)

      ["-" <> _ = switch | _rest] ->
        fail("Unknown option #{switch}: the command comes first.\n\n" <> @usage)

      [command | args] ->
        dispatch(command, args)
    end
  end

  defp dispatch(command, argv) do
    case List.keyfind(@commands, command, 0) do
      {^command, _args, _description, switches} ->
        case OptionParser.parse(argv, strict: [help: :boolean] ++ switches, aliases: [h: :help]) do
          {_opts, _args, [{switch, _value} | _rest]} ->
            fail(invalid_switch(command, switches, switch))

          {opts, args, []} ->
            if Keyword.get(opts, :help, false),
              do: puts(@usage),
              else: run(command, args, opts)
        end

      nil ->
        fail("Unknown command #{command}.\n\n" <> @usage)
    end
  end

  # Under strict parsing a declared switch with no value and an
  # undeclared one both arrive as invalid with a nil value, so the
  # command's own list is what tells them apart.
  defp invalid_switch(command, switches, switch) do
    declared = Enum.map(switches, fn {name, _type} -> "--#{name}" end)

    if switch in declared,
      do: "beamlet #{command}: #{switch} needs a value.",
      else: "beamlet #{command} does not take #{switch}; it takes: #{shape(command)}"
  end

  defp shape(command) do
    {^command, args, _description, _switches} = List.keyfind(@commands, command, 0)
    String.trim("#{command} #{args}")
  end

  defp run("setup", [], _opts), do: with_beamlet(&setup/0)
  defp run("tokens", [], _opts), do: with_beamlet(&list_tokens/0)

  defp run("tokens.create", [name], opts) do
    case one_policy("tokens.create", opts) do
      {:ok, attrs} -> with_beamlet(fn -> create_token(name, attrs) end)
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
  defp run("reset", [], _opts), do: reset()
  defp run(command, _args, _opts), do: fail("beamlet #{command} takes: " <> shape(command))

  # --policy is kept rather than overwritten, so a repeated one is
  # refused instead of the last silently winning.
  defp one_policy(command, opts) do
    case Keyword.get_values(opts, :policy) do
      [] -> {:ok, []}
      [policy] -> {:ok, [policy: policy]}
      _many -> {:error, "beamlet #{command} takes one --policy POLICY."}
    end
  end

  defp setup do
    case Owner.find() do
      {:ok, user} -> update_owner(user)
      {:error, :not_found} -> create_owner()
    end
  end

  # The email is checked before the password is asked for, so a bad
  # one fails before anyone types a password.
  defp create_owner do
    puts("Create your beamlet's owner account. Sign in to the app at /beamlet.")

    with {:ok, email} <- read_email(nil),
         :ok <- check_email(%User{}, email),
         {:ok, password} <- read_new_password(:required),
         {:ok, user} <- Owner.create(email: email, password: password) do
      puts("Set up the owner, #{user.email}.")
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp update_owner(user) do
    puts("Update your beamlet's owner account. A blank answer keeps the current value.")

    with {:ok, email} <- read_email(user.email),
         :ok <- check_email(user, email),
         {:ok, password} <- read_new_password(:optional),
         attrs = if(password, do: [email: email, password: password], else: [email: email]),
         {:ok, updated} <- Owner.update(user, attrs) do
      report_update(user, updated, password != nil)
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp report_update(user, updated, password?) do
    changes =
      if(updated.email != user.email, do: ["email #{updated.email}"], else: []) ++
        if password?, do: ["password"], else: []

    cond do
      changes == [] ->
        puts("Nothing changed.")

      password? ->
        puts("Updated the owner: #{Enum.join(changes, ", ")}.")
        puts("Every browser signed in to the app is signed out.")

      true ->
        puts("Updated the owner: #{Enum.join(changes, ", ")}.")
    end
  end

  defp read_email(current) do
    prompt = if current, do: "Email [#{current}]: ", else: "Email: "

    case IO.gets(prompt) do
      line when is_binary(line) ->
        case {String.trim(line), current} do
          {"", nil} -> {:error, "No email given."}
          {"", current} -> {:ok, current}
          {email, _current} -> {:ok, email}
        end

      _eof_or_error ->
        {:error, "No email given."}
    end
  end

  defp check_email(user, email) do
    changeset = User.changeset(user, %{email: email})

    case Keyword.take(changeset.errors, [:email]) do
      [] -> :ok
      errors -> {:error, %{changeset | errors: errors}}
    end
  end

  defp read_new_password(:required) do
    case read_password("Password: ") do
      {:ok, ""} -> {:error, "No password given."}
      {:ok, password} -> confirm_password(password)
      {:error, message} -> {:error, message}
    end
  end

  defp read_new_password(:optional) do
    case read_password("Password (blank keeps the current one): ") do
      {:ok, ""} -> {:ok, nil}
      {:ok, password} -> confirm_password(password)
      {:error, message} -> {:error, message}
    end
  end

  defp confirm_password(password) do
    case read_password("Again: ") do
      {:ok, ^password} -> {:ok, password}
      {:ok, _other} -> {:error, "Passwords do not match."}
      {:error, message} -> {:error, message}
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

  defp list_tokens do
    case Tokens.list() do
      [] ->
        puts("No tokens yet. Create one with: beamlet tokens.create <NAME>")

      tokens ->
        table(
          ["ID", "KIND", "LABEL", "POLICY", "EXPIRES", "CREATED"],
          Enum.map(
            tokens,
            &[&1.id, &1.kind, Token.label(&1), &1.policy, &1.expires_at || "-", &1.inserted_at]
          )
        )
    end
  end

  defp create_token(name, attrs) do
    case Tokens.create([name: name] ++ attrs) do
      {:ok, token} ->
        puts("Created token #{token.name} (policy #{token.policy}).")
        puts("Secret (shown once): #{token.secret}")

      {:error, changeset} ->
        fail(changeset)
    end
  end

  defp update_token(id, attrs) do
    with_token(id, fn token ->
      case Tokens.update(token, attrs) do
        {:ok, _updated} ->
          changes = Enum.map_join(attrs, ", ", fn {field, value} -> "#{field} #{value}" end)
          puts("Updated token #{Token.label(token)} (#{token.id}): #{changes}.")

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
      case Tokens.delete(token) do
        {:ok, _token} -> puts("Deleted token #{Token.label(token)} (#{token.id}).")
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

  # The route rows live in the beamlet's database, so the command
  # boots the system half as the token commands do. Deleting under a
  # running beamlet does no lasting harm, since it keeps what it has
  # loaded until it restarts and boots fresh after. The rows and the
  # database go before the code: code without them boots fresh, while
  # routes and migrations without their code name modules that are
  # gone.
  defp reset do
    with_beamlet(fn ->
      remove_routes()
      remove_agent_db(Config.agent_db_file())
      remove_dir(Config.code_dir(), "code dir and its history")
      remove_dir(Config.files_dir(), "files dir")

      puts("The owner, tokens and config.exs are kept. If a beamlet is running, restart it now.")
    end)
  rescue
    error in File.Error ->
      fail("""
      #{Exception.message(error)}
      The reset stopped partway: what is listed as removed is gone, the rest is not. \
      Fix the cause and run `beamlet reset` again.\
      """)
  end

  defp remove_dir(dir, label) do
    if File.dir?(dir) do
      File.rm_rf!(dir)
      puts("Removed the #{label}: #{dir}")
    else
      puts("No #{label} at #{dir}")
    end
  end

  defp remove_routes do
    case Routes.delete_all() do
      0 -> puts("No routes mounted")
      1 -> puts("Removed 1 route")
      count -> puts("Removed #{count} routes")
    end
  end

  defp remove_agent_db(db_file) do
    files = Enum.filter([db_file, db_file <> "-wal", db_file <> "-shm"], &File.exists?/1)

    if files == [] do
      puts("No agent database at #{db_file}")
    else
      Enum.each(files, &File.rm!/1)
      puts("Removed the agent database: #{db_file}")
    end
  end

  defp with_token(id, fun) do
    with {number, ""} <- Integer.parse(id),
         {:ok, token} <- Tokens.find(number) do
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

        {:error, reason} ->
          fail(boot_error(reason))
      end
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  # A child that fails to start arrives wrapped; an exception raised in
  # Beamlet.init/1 itself, a bad config or a missing dir, arrives bare.
  defp boot_error({:shutdown, {:failed_to_start_child, _child, reason}}), do: boot_error(reason)
  defp boot_error({error, _stack}) when is_exception(error), do: Exception.message(error)
  defp boot_error(reason), do: "The beamlet failed to start: #{inspect(reason)}"

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
