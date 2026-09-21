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

  Every test also gets a user, `alice`, and one of her tokens as
  `user` and `token`, created through `Beamlet.Users` so a test
  authenticates the way production does. The token still carries its
  `secret`; `principal/1` turns it into the principal a request
  would carry, and `act_as/1` makes it the test process's ambient
  principal, as eval's runtime does for evaluated code, for tests
  that call `Host.*` directly.

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

  alias Beamlet.Principal
  alias Beamlet.Token
  alias Beamlet.Users
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

    {:ok, user} = Users.create(name: "alice")
    {:ok, token} = Users.create_token(user, name: "test")

    %{data_dir: Beamlet.Config.data_dir(), user: user, token: token}
  end

  @doc "The principal a request with this token carries, built the way the plug builds it."
  @spec principal(Token.t()) :: Principal.t()
  def principal(%Token{secret: secret}) do
    {:ok, authenticated} = Users.authenticate(secret)
    Principal.from_token(authenticated)
  end

  @doc "Makes the token's principal the calling process's ambient one (`Beamlet.Principal.put_current/1`)."
  @spec act_as(Token.t()) :: :ok
  def act_as(%Token{} = token), do: token |> principal() |> Principal.put_current()

  @doc "Signs the user in on the conn's test session, as `Beamlet.Web.Auth.log_in/2` would."
  @spec sign_in(Plug.Conn.t(), Beamlet.User.t()) :: Plug.Conn.t()
  def sign_in(conn, %Beamlet.User{id: id}) do
    Plug.Test.init_test_session(conn, user_id: id)
  end

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
