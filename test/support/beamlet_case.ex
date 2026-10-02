defmodule Beamlet.Case do
  @moduledoc """
  Test case for anything that needs a running beamlet.

  Starts one under the test supervisor against the configured
  per-run data dir and hands the path to the test as `data_dir`.
  Each test owns a sandbox connection on both repos, shared with
  every process in the VM, so rows written during a test roll back
  when it ends while the schema migrated at boot stays. The code and
  files dirs are wiped before the beamlet starts, so every test boots
  with no defined modules, a fresh history and no files, and the
  last test's dirs stay inspectable after the run.

  Every test also gets the owner and one token, as `user` and `token`,
  created through `Beamlet.Owner` and `Beamlet.Tokens` so a test
  authenticates the way production does; the owner's password is
  `password`. The token still carries its `secret`; `principal/1`
  turns it into the principal a request would carry, and `act_as/1`
  makes it the test process's ambient principal, as eval's runtime
  does for evaluated code, for tests that call `Host.*` directly.
  `sign_in/1` signs the owner in on a conn.

  The test endpoint (`Beamlet.TestEndpoint`) starts after the beamlet,
  so every test can request the routes it mounts through
  `Phoenix.ConnTest` and `Phoenix.LiveViewTest`; `@endpoint` is set.

  A test declares policies for its beamlet with a tag in the shape
  config takes, put into config before the beamlet starts and removed
  after, and likewise the web keys merged over the configured ones:

      @tag policies: [restricted: [tools: [:eval]]]
      @tag web: [prefix: "/pages"]

  Tests that define modules touch VM-global state, loaded modules and
  the compiler's tracer list, so they run `async: false` and use
  `unique_namespace/0` and `purge_on_exit/1`.
  """

  use ExUnit.CaseTemplate

  alias Beamlet.Owner
  alias Beamlet.Principal
  alias Beamlet.Token
  alias Beamlet.Tokens
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @endpoint Beamlet.TestEndpoint

      import Beamlet.Case
    end
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

    File.rm_rf!(Beamlet.Config.code_dir())
    File.rm_rf!(Beamlet.Config.files_dir())
    preserve_compiler_tracers()
    start_supervised!({Beamlet, []})
    start_supervised!(Beamlet.TestEndpoint)

    for repo <- [Beamlet.Repo, Host.Repo] do
      owner = Sandbox.start_owner!(repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(owner) end)
    end

    password = "correct horse"
    {:ok, user} = Owner.create(email: "owner@example.com", password: password)
    {:ok, token} = Tokens.create(name: "test")

    %{data_dir: Beamlet.Config.data_dir(), user: user, password: password, token: token}
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
