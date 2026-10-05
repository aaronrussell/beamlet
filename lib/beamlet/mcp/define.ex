defmodule Beamlet.MCP.Define do
  @moduledoc ~S"""
  The `define` tool, which compiles modules into your beamlet and
  keeps them.

  An agent sends one or more modules. Each is checked against the
  token's policy and compiled into the running beamlet, ready to call
  straight away, and stays across restarts. Either all the modules
  land or none do.

  Every module is saved in the code dir and committed to its git
  history, with the token that wrote it as the author.

  A module that exists already is replaced only when its entry says
  `replace: true`. The names `Beamlet.*` and `Host.*` are reserved.
  Every module needs a `@moduledoc` and every public function a
  `@doc`, so the next agent can find its way around.

  A token has the tool when its policy lists `:define` under `tools`,
  which brings `patch` with it. `default` does.

  ## Input

  ```json
  {
    "modules": [
      {"code": "defmodule Shopping.List do..."},
      {"code": "defmodule Shopping.Item do...", "replace": true}
    ]
  }
  ```

  * `modules` - Required. The modules to define, each with:
    * `code` - Required. The source of one top-level `defmodule`.
    * `replace` - `true` to replace a module that already exists.
      Defaults to `false`.

  ## Configuration

      config :beamlet, define: [timeout: 60_000]

  * `:timeout` - How long one `define` or `patch` may take to
    compile, in milliseconds. Defaults to 30 seconds.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Beamlet.Define
  alias Beamlet.MCP.Server

  schema do
    embeds_many :modules, required: true, description: "The modules to define, one per entry" do
      field :code, {:required, :string}, description: "One top-level defmodule"

      field :replace, :boolean,
        description: """
        Set true to deliberately replace this module if it exists. \
        Harmless on a new one. Default false.
        """
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
