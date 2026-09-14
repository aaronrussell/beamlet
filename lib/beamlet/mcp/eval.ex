defmodule Beamlet.MCP.Eval do
  @moduledoc false

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field(:code, {:required, :string}, description: "Elixir code to evaluate")
  end

  @impl true
  def description do
    """
    Evaluate Elixir code on your beamlet and return the inspected
    result. The standard library, the `Host.*` stdlib and every module
    defined on this beamlet are callable; what else is allowed is set
    by policy, and a refused call is an error naming the alternative.
    """
  end

  @impl true
  def execute(_params, frame) do
    {:reply, Response.error(Response.tool(), "eval is not available yet on this beamlet"), frame}
  end
end
