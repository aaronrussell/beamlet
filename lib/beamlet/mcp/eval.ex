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

    Your beamlet is a running Elixir application you extend from the
    inside. Start here: `Host.Code.print_modules()` lists what exists,
    `Host.Code.print_docs(Module)` prints the documentation of any
    module you may call, and `Host.Code.print_policy()` shows what
    your code may not. The `Host.*` modules are the stdlib: files,
    key/value state, the agent database and its migrations, pubsub
    and the web surface; each one's docs carry the conventions for
    its area. Everything defined on this beamlet is callable too, and
    a refused call is an error naming the alternative.

    Worth knowing: each call is a fresh evaluation with empty
    bindings; the `print_*` functions print and return `:ok`, and
    several fit in one call; put `import Ecto.Query` at the top of
    any code that queries; the beamlet is shared with other users and
    agents, so read what exists before building; verify before
    reporting done, with `Host.Router.call(verb, path)` on a route
    and a query on the rows you wrote.

    The result is whatever the code printed, then `=> ` and the
    inspected value of the last expression; the output cap is
    #{kb(limits[:max_output])} and the timeout #{seconds(limits[:timeout])},
    after which you get what was printed up to then. End with `:ok`
    when only the printed output matters, and look at large data with
    `IO.inspect(data, limit: 20)` rather than returning it whole.
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
