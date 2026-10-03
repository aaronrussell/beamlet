defmodule Beamlet.MCP.Define do
  @moduledoc """
  The `define` tool: write modules into a beamlet, compiled and kept.

  Each use takes a list of entries, one top-level `defmodule` each.
  The modules are scanned against the token's policy, checked for
  docs, compiled into the running beamlet and stored under the data
  dir's `code/`. They are callable at once and reloaded at boot. The
  entries land together or not at all: on any error nothing changes,
  and the error says what to fix.

  Changing a module that exists needs `replace: true` on its entry,
  and recompiles the modules that depend on it; a change that drops a
  function another module still calls is refused. `Beamlet.*` and
  `Host.*` are reserved. Every module needs a `@moduledoc` and every
  public function a `@doc`, since docs are how the next agent finds
  it; a module whose functions are framework callbacks, a LiveView, a
  controller, a migration or an Ecto type, needs only the
  `@moduledoc`. A module that uses `Ecto.Migration` is filed as a
  numbered migration and waits for `Host.Migrator`.

  A token may use the tool when its policy lists `:define` under
  `tools` (`Beamlet.Policy`), which grants `patch` with it; `default`
  does.

  ## The code dir

  `code/` holds the sources under `lib/`, numbered migrations under
  `migrations/`, and the compiled modules under `ebin/`. It is a git
  repository, and every define, patch and removal is one commit: the
  subject names the modules, and the trailers name the token and its
  policy. `git log` in the code dir is the record of everything built
  and torn down, and by whom.

  ## Limits

  One limit, set in config: `timeout` (30 seconds) is how long one
  define may take to compile, since a define holds the beamlet's one
  lane for code changes. `patch` shares it.

      config :beamlet, define: [timeout: 30_000]
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Beamlet.Define
  alias Beamlet.MCP.Server

  schema do
    embeds_many :modules, required: true, description: "The modules to define, one per entry" do
      field(:code, {:required, :string}, description: "One top-level defmodule")

      field(:replace, :boolean,
        description:
          "Set true to deliberately replace this module if it exists. Harmless on a new one. " <>
            "Default false."
      )
    end
  end

  @doc """
  The description a client lists for the tool, written for the model.

  Built when it is read, from the `timeout` above, so it always
  states the one in force.
  """
  @impl true
  def description do
    limits = Beamlet.Config.define()

    """
    Define modules on your beamlet: durable Elixir code, compiled and kept.

    Each entry is one top-level `defmodule`. The modules are compiled
    into the running system, kept on disk and reloaded at boot,
    callable from `eval` and from other modules straight away.
    Explore with `eval` first: `Host.Code.print_modules()` shows what
    exists.

    `Beamlet.*` and `Host.*` are reserved; pick clear dotted names
    like `Shopping.List`. Every module needs a `@moduledoc` and every
    public function a `@doc`, since docs are how a module is found
    later; a module whose functions are framework callbacks (a
    `use Host.Web` role, `Ecto.Migration`, `Ecto.Type`) needs only the
    `@moduledoc`. Your policy applies inside module bodies as it does
    in `eval`. Source is stored formatted, and errors and stack
    traces locate as `lib/shopping/list.ex:42`, a line of what
    `Host.Code.print_source(Shopping.List)` prints.

    A module that already exists is refused unless its entry sets
    `replace: true`; to change part of it, `patch` it instead. The
    flag is permission, not an assertion, so it is harmless on a new
    module. A replace recompiles the module's
    dependents, and a mounted route serves the new module without
    remounting; dropping a function another module still calls is
    refused, and if a dependent no longer compiles the error names it.

    The entries land together or not at all: on any error nothing is
    changed. To land modules independently, make one call per module.
    A module that uses `Ecto.Migration` is filed as a numbered
    migration, pending until `Host.Migrator.migrate()` runs it. A
    define stops after #{Server.seconds(limits[:timeout])}.
    """
  end

  @impl true
  def execute(%{modules: modules}, frame) do
    with :ok <- Server.authorize("define", frame) do
      entries = Enum.map(modules, &%{code: &1[:code], replace: &1[:replace] == true})

      case Define.run(entries, frame.assigns.principal) do
        {:ok, text} -> {:reply, Response.text(Response.tool(), text), frame}
        {:error, text} -> {:reply, Response.error(Response.tool(), text), frame}
      end
    end
  end
end
