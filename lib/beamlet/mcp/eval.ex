defmodule Beamlet.MCP.Eval do
  @moduledoc ~S"""
  The `eval` tool, which runs Elixir code on your beamlet.

  Each use is a fresh evaluation, with nothing carried over from the
  last. The code is checked against the token's policy before it
  runs. It can call what the policy grants and every module agents
  have defined.

  The agent gets back what the code printed, then the value of its
  last expression. A refused call, an exception or a timeout comes
  back as text too, so the agent can see what went wrong and try
  again.

  A token has the tool when its policy lists `:eval` under `tools`.
  `default` does.

  ## Input

  ```json
  {"code": "Shopping.List.items() |> length()"}
  ```

  * `code` - Required. The Elixir code to evaluate.

  ## Configuration

      config :beamlet, eval: [timeout: 60_000]

  * `:timeout` - How long one evaluation may run, in milliseconds.
    When it runs out, the evaluation stops and the output so far
    comes back. Defaults to 30 seconds. The MCP server's
    `:request_timeout` must stay longer (`Beamlet.MCP.Server`).
  * `:max_heap_bytes` - How much memory one evaluation may use.
    Past it, the evaluation stops before it can take the beamlet
    down. Defaults to 128 MB.
  * `:max_output` - How much printed output comes back, in bytes.
    Longer output is cut, with a line saying how much was shown.
    Defaults to 32 KB.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Beamlet.Eval
  alias Beamlet.MCP.Server

  schema do
    field :code, {:required, :string}, description: "Elixir code to evaluate"
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
