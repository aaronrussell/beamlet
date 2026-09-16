defmodule Beamlet.MCP.Eval do
  @moduledoc false

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Beamlet.Eval

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
  def execute(%{code: code}, frame) do
    case Eval.run(code, frame.assigns.principal) do
      {:ok, text} -> {:reply, Response.text(Response.tool(), text), frame}
      {:error, text} -> {:reply, Response.error(Response.tool(), text), frame}
    end
  end
end
