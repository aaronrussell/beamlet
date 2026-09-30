defmodule Beamlet.MCP.Define do
  @moduledoc false

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
    define stops after #{seconds(limits[:timeout])}.
    """
  end

  defp seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)} seconds"
  defp seconds(ms), do: "#{ms}ms"

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
