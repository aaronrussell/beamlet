defmodule Beamlet.MCP.Eval do
  @moduledoc """
  The `eval` tool: run Elixir code on a beamlet and hand back what it
  printed and returned.

  Each use is a fresh evaluation inside the beamlet's own VM, with
  empty bindings and nothing carried over from the last. The code is
  scanned against the token's policy before it runs, and may call
  whatever the policy grants and every module defined on the beamlet.
  The result is the printed output, then `=> ` and the inspected
  value of the last expression. A refused call, a raised exception
  and a timeout come back as text too, after the output printed
  before them, so an agent reads what went wrong and tries again.

  A token may use the tool when its policy lists `:eval` under
  `tools` (`Beamlet.Policy`); `default` does.

  ## Limits

  Three limits, set in config, each protecting one thing:

      config :beamlet,
        eval: [timeout: 30_000, max_heap_bytes: 134_217_728, max_output: 32_768]

  - `timeout` (30 seconds) protects the session. An MCP session runs
    one request at a time, so a run that never ended would stall
    every request behind it. The evaluation is stopped and the output
    so far returned. The MCP request timeout (`Beamlet.Config.mcp/0`)
    must be longer, so it is never the one that fires.
  - `max_heap_bytes` (128MB) protects the beamlet: a runaway
    allocation is stopped before it takes the VM down. Binaries the
    code holds count, however large.
  - `max_output` (32KB) protects the model's context. Only the first
    32KB printed is ever held, and a longer result is cut with a line
    saying how much was shown of how much. The result or error after
    the output is kept whole when it fits, the output taking the room
    left, since that line is what the agent acts on. 32KB is under
    the point where Claude Code warns about a large tool result.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Beamlet.Eval
  alias Beamlet.MCP.Server

  schema do
    field(:code, {:required, :string}, description: "Elixir code to evaluate")
  end

  @doc """
  The description a client lists for the tool, written for the model.

  Built when it is read, from the limits above, so it always states
  the ones in force.
  """
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
    any code that queries; other agents and earlier sessions build
    here too, so read what exists before building; verify before
    reporting done, with `Host.Router.call(verb, path)` on a route
    and a query on the rows you wrote.

    The result is whatever the code printed, then `=> ` and the
    inspected value of the last expression; the output cap is
    #{kb(limits[:max_output])} and the timeout #{Server.seconds(limits[:timeout])},
    after which you get what was printed up to then. End with `:ok`
    when only the printed output matters, and look at large data with
    `IO.inspect(data, limit: 20)` rather than returning it whole.
    """
  end

  defp kb(bytes) when rem(bytes, 1024) == 0, do: "#{div(bytes, 1024)}KB"
  defp kb(bytes), do: "#{bytes} bytes"

  @impl true
  def execute(%{code: code}, frame) do
    with :ok <- Server.authorize("eval", frame) do
      case Eval.run(code, frame.assigns.principal) do
        {:ok, text} -> {:reply, Response.text(Response.tool(), text), frame}
        {:error, text} -> {:reply, Response.error(Response.tool(), text), frame}
      end
    end
  end
end
