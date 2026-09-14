defmodule Beamlet.MCP.Define do
  @moduledoc false

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

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
    Defining a module that already exists is refused unless `replace`
    is true.
    """
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.error(Response.tool(), "define is not available yet on this beamlet"),
     frame}
  end
end
