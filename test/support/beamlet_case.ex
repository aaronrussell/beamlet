defmodule Beamlet.Case do
  @moduledoc """
  Test case for anything that needs a running beamlet.

  Starts one under the test supervisor against the configured
  per-run data dir and hands the path to the test as `data_dir`.
  Each test owns a sandbox connection on both repos, shared with
  every process in the VM, so rows written during a test roll back
  when it ends while the schema migrated at boot stays. The code dir
  is wiped before the beamlet starts, so every test boots with no
  defined modules and a fresh history, and the last test's code dir
  stays inspectable after the run.

  Every test also gets a user, `alice`, and one of her tokens as
  `user` and `token`, created through `Beamlet.Users` so a test
  authenticates the way production does. The token still carries its
  `secret`; `principal/1` turns it into the principal a request
  would carry.

  A test declares policies for its beamlet with a tag in the shape
  config takes, put into config before the beamlet starts and removed
  after:

      @tag policies: [restricted: [tools: [:eval]]]

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
      import Beamlet.Case
    end
  end

  setup context do
    if policies = context[:policies] do
      Application.put_env(:beamlet, :policies, policies)
      on_exit(fn -> Application.delete_env(:beamlet, :policies) end)
    end

    File.rm_rf!(Beamlet.Config.code_dir())
    preserve_compiler_tracers()
    start_supervised!({Beamlet, []})

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
