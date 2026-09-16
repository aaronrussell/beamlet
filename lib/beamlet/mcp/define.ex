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
    """
    Define one or more modules on your beamlet. The code is compiled
    into the running system, kept on disk and reloaded at boot, and
    every module becomes callable from `eval` and from other modules.
    The buffer is top-level `defmodule`s only; every module needs a
    `@moduledoc` and every public function a `@doc`, since docs are
    how a module is found later. Defining a module that already
    exists is refused unless `replace` is true.
    """
  end

  @impl true
  def execute(%{code: code} = params, frame) do
    case Define.run(code, frame.assigns.principal, replace: Map.get(params, :replace, false)) do
      {:ok, text} -> {:reply, Response.text(Response.tool(), text), frame}
      {:error, text} -> {:reply, Response.error(Response.tool(), text), frame}
    end
  end
end
