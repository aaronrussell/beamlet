defmodule Beamlet.Case do
  @moduledoc """
  Test case for anything that needs a running beamlet.

  Starts one under the test supervisor against the configured
  per-run data dir and hands the path to the test as `data_dir`.
  Each test owns a sandbox connection on both repos, shared with
  every process in the VM, so rows written during a test roll back
  when it ends while the schema migrated at boot stays.

  By default every test gets a beamlet of its own, booted with no
  defined modules, a fresh history, an empty agent database and no
  files: the code dir is a copy of the one the run's first boot
  wrote, so a boot finds a clean repo and skips git's `init`, and the
  router in the VM is the compiled-in placeholder. The last test's
  dirs stay inspectable after the run.

  `Host.Migrator` runs migrations on a connection of its own, which
  the sandbox's open transaction would block and whose commits it
  could not see. A module whose tests migrate turns the sandbox off
  for the agent database, which then runs on Ecto's ordinary pool as
  in production, so what its tests write there is committed, and the
  next test's boot deletes it:

      use Beamlet.Case, agent_sandbox: false

  A module whose tests change only rows, which the sandbox isolates,
  shares one beamlet across its tests instead, started before the
  first and stopped after the last:

      use Beamlet.Case, shared: true

  Each test still gets the policies built from its tags, an empty
  OAuth client cache and code store, and an empty files dir. A shared
  test must not define, patch or remove code, mount routes or restart
  the beamlet's children: the defined and quarantined sets are checked
  after each test, and a test that changed them fails, since the next
  test would see what it left.

  Sharing a beamlet among tests that change code was weighed and kept
  out: the suite's most precise assertions, on the defined set, the
  history and migration numbers, would depend on what ran before.
  `mix test --partitions` with a data dir per partition runs faster
  but needs a wrapper or a CI matrix, and was not adopted.

  Every test also gets the owner and one token, as `user` and `token`,
  created through `Beamlet.Owner` and `Beamlet.Tokens` so a test
  authenticates the way production does; the owner's password comes as
  `password`. The token still carries its `secret`; `principal/1`
  turns it into the principal a request would carry, and `act_as/1`
  makes it the test process's ambient principal, as eval's runtime
  does for evaluated code, for tests that call `Host.*` directly.
  `sign_in/1` signs the owner in on a conn.

  The test endpoint (`Beamlet.TestEndpoint`) starts after the beamlet,
  so every test can request the routes it mounts through
  `Phoenix.ConnTest` and `Phoenix.LiveViewTest`; `@endpoint` is set.

  A test declares policies for its beamlet with a tag in the shape
  config takes, put into config before the policies are built and
  removed after, and likewise the web keys merged over the configured
  ones:

      @tag policies: [restricted: [tools: [:eval]]]
      @tag web: [prefix: "/pages"]

  The agent database's repo options take the same shape:

      @tag agent_repo: [pool_size: 10]

  One beamlet runs per VM, its processes and tables named, so a
  module using this case is never async. Tests that define modules
  use `unique_namespace/0` and `purge_on_exit/1`, since loaded modules
  outlive the beamlet that defined them.
  """

  use ExUnit.CaseTemplate

  alias Beamlet.Owner
  alias Beamlet.Principal
  alias Beamlet.Token
  alias Beamlet.Tokens
  alias Ecto.Adapters.SQL.Sandbox

  using opts do
    if opts[:async] do
      raise ArgumentError, "Beamlet.Case cannot be async: one beamlet runs per VM"
    end

    agent_sandbox = Keyword.get(opts, :agent_sandbox, true)

    if opts[:shared] && !agent_sandbox do
      raise ArgumentError,
            "Beamlet.Case cannot share a beamlet without the agent database's sandbox: " <>
              "what one test commits there, the next would see"
    end

    quote do
      @endpoint Beamlet.TestEndpoint
      @moduletag beamlet: if(unquote(opts[:shared]), do: :shared, else: :per_test)
      @moduletag agent_sandbox: unquote(agent_sandbox)

      import Beamlet.Case
    end
  end

  setup_all context do
    if context.beamlet == :shared, do: boot!()
    :ok
  end

  setup context do
    if policies = context[:policies] do
      Application.put_env(:beamlet, :policies, policies)
      on_exit(fn -> Application.delete_env(:beamlet, :policies) end)
    end

    if web = context[:web] do
      configured = Application.fetch_env!(:beamlet, :web)
      Application.put_env(:beamlet, :web, Keyword.merge(configured, web))
      on_exit(fn -> Application.put_env(:beamlet, :web, configured) end)
    end

    preserve_compiler_tracers()

    agent_repo =
      if(context.agent_sandbox, do: [], else: [pool: DBConnection.ConnectionPool])
      |> Keyword.merge(context[:agent_repo] || [])

    if agent_repo != [] do
      configured = Application.fetch_env!(:beamlet, Host.Repo)
      Application.put_env(:beamlet, Host.Repo, Keyword.merge(configured, agent_repo))
      on_exit(fn -> Application.put_env(:beamlet, Host.Repo, configured) end)
    end

    case context.beamlet do
      :shared -> refresh_shared!()
      :per_test -> boot!()
    end

    repos = if context.agent_sandbox, do: [Beamlet.Repo, Host.Repo], else: [Beamlet.Repo]

    for repo <- repos do
      owner = Sandbox.start_owner!(repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(owner) end)
    end

    password = "correct horse"
    {:ok, user} = Owner.create(email: "owner@example.com", password: password)
    {:ok, token} = Tokens.create(name: "test")

    %{data_dir: Beamlet.Config.data_dir(), user: user, password: password, token: token}
  end

  @doc false
  @spec code_template_dir() :: Path.t()
  def code_template_dir, do: Beamlet.Config.data_dir() <> "_code_template"

  # The template is the code dir the run's first boot wrote, so every
  # later boot finds a repo with its initial snapshot and sweeps it
  # rather than running git's init and first commit, three processes.
  # The agent database goes too, since a test outside its sandbox
  # commits what it writes there.
  defp boot! do
    template = code_template_dir()
    agent_db_file = Beamlet.Config.agent_db_file()
    Enum.each(["", "-wal", "-shm"], &File.rm(agent_db_file <> &1))
    File.rm_rf!(Beamlet.Config.code_dir())
    if File.dir?(template), do: File.cp_r!(template, Beamlet.Config.code_dir())
    File.rm_rf!(Beamlet.Config.files_dir())
    restore_placeholder_router()

    start_supervised!({Beamlet, []})
    start_supervised!(Beamlet.TestEndpoint)

    unless File.dir?(template), do: File.cp_r!(Beamlet.Config.code_dir(), template)
  end

  # A test that follows a routing test would otherwise boot with that
  # test's router loaded.
  defp restore_placeholder_router do
    if Beamlet.DynamicRouter.__routes__() != [] do
      :code.purge(Beamlet.DynamicRouter)
      {:module, _} = :code.load_file(Beamlet.DynamicRouter)
      :code.purge(Beamlet.DynamicRouter)
    end
  end

  # What a shared beamlet holds per test beyond the sandbox: the
  # policies built from this test's tags, the OAuth client cache and
  # code store, and the files dir.
  defp refresh_shared! do
    for child <- [Beamlet.Policies, Beamlet.OAuth.Clients, Beamlet.OAuth.Codes] do
      :ok = Supervisor.terminate_child(Beamlet, child)
      {:ok, _pid} = Supervisor.restart_child(Beamlet, child)
    end

    File.rm_rf!(Beamlet.Config.files_dir())
    File.mkdir_p!(Beamlet.Config.files_dir())

    on_exit(fn ->
      changed = Beamlet.Code.defined() ++ Enum.map(Beamlet.Code.quarantined(), & &1.file)

      if changed != [] do
        raise "this test shares its module's beamlet and left code behind " <>
                "(#{inspect(changed)}); a test that defines code needs a beamlet of its " <>
                "own: drop `shared: true` from the module or move the test"
      end
    end)
  end

  @doc "The principal a request with this token carries, built the way the plug builds it."
  @spec principal(Token.t()) :: Principal.t()
  def principal(%Token{secret: secret}) do
    {:ok, authenticated} = Tokens.authenticate(secret)
    Principal.from_token(authenticated)
  end

  @doc "Makes the token's principal the calling process's ambient one (`Beamlet.Principal.put_current/1`)."
  @spec act_as(Token.t()) :: :ok
  def act_as(%Token{} = token), do: token |> principal() |> Principal.put_current()

  @doc "Signs the owner in on the conn's test session, as `Beamlet.Web.Auth.log_in/2` would."
  @spec sign_in(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_in(conn) do
    {:ok, session} = Owner.create_session()

    Plug.Test.init_test_session(conn,
      session_secret: session.secret,
      live_socket_id: "beamlet_app_session:#{session.id}"
    )
  end

  @doc """
  An entry for `Beamlet.Code.define/3` from one module's source, as the
  runtime hands it over but unformatted, unscanned and unchecked: the
  module from the source's one `defmodule`, its kind from a
  `use Ecto.Migration` line, and `replace:` from `opts`.
  """
  @spec entry(String.t(), keyword()) :: Beamlet.Code.entry()
  def entry(source, opts \\ []) when is_binary(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    forms = block_forms(ast)

    [{:defmodule, _meta, [{:__aliases__, _, parts}, [do: body]]}] =
      Enum.filter(forms, &match?({:defmodule, _, _}, &1))

    migration? =
      Enum.any?(block_forms(body), fn
        {:use, _meta, [{:__aliases__, _, [:Ecto, :Migration]} | _opts]} -> true
        _form -> false
      end)

    %{
      module: Module.concat(parts),
      source: source,
      kind: if(migration?, do: :migration, else: :module),
      replace: Keyword.get(opts, :replace, false)
    }
  end

  defp block_forms({:__block__, _meta, forms}), do: forms
  defp block_forms(form), do: [form]

  @doc "A module namespace unique to one test, e.g. `BeamletT42`, so defined modules never collide."
  @spec unique_namespace() :: String.t()
  def unique_namespace, do: "BeamletT#{System.unique_integer([:positive])}"

  @doc "Whether the module is loaded in the VM; `Code.ensure_loaded?/1` under a name that does not clash with `Beamlet.Code`."
  @spec loaded?(module()) :: boolean()
  def loaded?(mod), do: :code.is_loaded(mod) != false

  @doc "Purges and deletes the modules from the VM when the test exits."
  @spec purge_on_exit([module()]) :: :ok
  def purge_on_exit(modules) do
    on_exit(fn ->
      Enum.each(modules, fn mod ->
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
      end)
    end)
  end

  @doc "Runs `fun` with stderr captured, where a failing compile prints its diagnostics, and returns its result."
  @spec quiet((-> result)) :: result when result: term()
  def quiet(fun) do
    ExUnit.CaptureIO.capture_io(:stderr, fn -> send(self(), {:quiet_result, fun.()}) end)

    receive do
      {:quiet_result, result} -> result
    end
  end

  @doc """
  Makes every router build fail until the test exits.

  No route row can break the build: a path Phoenix refuses fails the
  row's validations. A glob in the prefix, which config refuses at
  boot but not when changed after it, leaves every route's path with
  a glob before its end, which Phoenix refuses.
  """
  @spec break_router_build() :: :ok
  def break_router_build do
    configured = Application.fetch_env!(:beamlet, :web)
    Application.put_env(:beamlet, :web, Keyword.put(configured, :prefix, "/*broken"))
    on_exit(fn -> Application.put_env(:beamlet, :web, configured) end)
  end

  @doc "Restores the compiler's tracer list when the test exits."
  @spec preserve_compiler_tracers() :: :ok
  def preserve_compiler_tracers do
    tracers = Code.get_compiler_option(:tracers)
    on_exit(fn -> Code.put_compiler_option(:tracers, tracers) end)
  end

  @doc "Changeset errors as a map of field to messages, with values interpolated."
  @spec errors_on(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
