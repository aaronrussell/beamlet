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
    limits = Beamlet.Config.eval()

    """
    Evaluate Elixir code on your beamlet and return the result.

    The standard library, the `Host.*` stdlib and every module defined
    on this beamlet are callable; what else is allowed is set by your
    policy, and a refused call is an error naming the alternative.
    Each call is a fresh evaluation with empty bindings.

    The result is whatever the code printed, then `=> ` and the
    inspected value of the last expression, cut at
    #{kb(limits[:max_output])}. End with `:ok` when only the printed
    output matters, and look at large data with
    `IO.inspect(data, limit: 20)` rather than returning it whole.
    Evaluation stops after #{seconds(limits[:timeout])} or on runaway
    memory, and you get what was printed up to then.
    """
  end

  defp kb(bytes) when rem(bytes, 1024) == 0, do: "#{div(bytes, 1024)}KB"
  defp kb(bytes), do: "#{bytes} bytes"

  defp seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)} seconds"
  defp seconds(ms), do: "#{ms}ms"

  @impl true
  def execute(%{code: code}, frame) do
    case Eval.run(code, frame.assigns.principal) do
      {:ok, text} -> {:reply, Response.text(Response.tool(), text), frame}
      {:error, text} -> {:reply, Response.error(Response.tool(), text), frame}
    end
  end
end
