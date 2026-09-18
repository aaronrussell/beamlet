defmodule Beamlet.MCP.Define do
  @moduledoc false

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Beamlet.Define

  schema do
    field(:code, {:required, :string}, description: "One or more top-level defmodule definitions")

    field(:replace, :boolean,
      description: "Set true to deliberately replace modules you defined before. Default false."
    )
  end

  @impl true
  def description do
    limits = Beamlet.Config.define()

    """
    Define one or more modules on your beamlet: compiled into the
    running system, kept on disk and reloaded at boot, callable from
    `eval` and from other modules straight away.

    The code is top-level `defmodule`s only: no loose expressions, no
    nested modules. `Beamlet.*` and `Host.*` are reserved; pick clear
    dotted names like `Shopping.List`. Every module needs a
    `@moduledoc` and every public function a `@doc`, since docs are
    how a module is found later; a module whose functions are
    framework callbacks (a `use Host.Web` role, `Ecto.Migration`,
    `Ecto.Type`) needs only the `@moduledoc`. Your policy applies
    inside module bodies as it does in `eval`.

    A module that already exists is refused unless `replace` is true.
    The flag is permission, not an assertion, so it is harmless on a
    new module. A replace recompiles the module's dependents, and a
    mounted route serves the new module without remounting; dropping
    a function another module still calls is refused, and if a
    dependent no longer compiles the error names it and nothing
    changes.

    A module that uses `Ecto.Migration` is filed as a numbered
    migration, pending until `Host.Migrator.migrate()` runs it. A
    define stops after #{seconds(limits[:timeout])}, and on any
    error nothing is changed.
    """
  end

  defp seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)} seconds"
  defp seconds(ms), do: "#{ms}ms"

  @impl true
  def execute(%{code: code} = params, frame) do
    case Define.run(code, frame.assigns.principal, replace: Map.get(params, :replace, false)) do
      {:ok, text} -> {:reply, Response.text(Response.tool(), text), frame}
      {:error, text} -> {:reply, Response.error(Response.tool(), text), frame}
    end
  end
end
