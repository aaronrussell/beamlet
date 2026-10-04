defmodule Beamlet.MCP.Server do
  @moduledoc """
  The MCP server agents connect to, at `/beamlet/mcp`.

  It offers three tools:

  * `Beamlet.MCP.Define` - the `define` tool, which compiles modules
    into your beamlet.
  * `Beamlet.MCP.Eval` - the `eval` tool, which runs Elixir code on
    your beamlet.
  * `Beamlet.MCP.Patch` - the `patch` tool, which edits a module
    agents defined.

  Every request needs a token, and the token's policy decides which
  of the tools the client sees.

  ## Configuration

      config :beamlet, mcp: [request_timeout: 90_000]

  * `:request_timeout` - How long the server waits for a tool to
    answer before replying "Server unavailable", in milliseconds.
    Defaults to 65 seconds. It must be longer than the eval and
    define timeouts, so a slow tool reports its own error first.
  """

  @version Mix.Project.config()[:version]

  use Anubis.Server, name: "beamlet", version: @version, capabilities: [:tools]

  alias Anubis.MCP.Error
  alias Anubis.Server.Handlers
  alias Beamlet.Policies
  alias Beamlet.Policy

  component(Beamlet.MCP.Define)
  component(Beamlet.MCP.Eval)
  component(Beamlet.MCP.Patch)

  @instructions """
  These tools work on your beamlet: a running Elixir application you
  extend from the inside. They apply only when working on it.

  `eval` evaluates Elixir code on your beamlet and returns the
  result. `define` compiles modules, one per entry, into the running
  system and keeps them across restarts; anything worth calling
  again belongs in a module. `patch` edits a defined module's source
  by find and replace or by function. Your policy sets which of the
  three you have: `Host.Code.print_policy()` names them, and a tool
  it withholds is not in your list.

  Start with `eval`. `Host.Code.print_modules()` lists what exists,
  `Host.Code.print_docs(Module)` prints the documentation of any
  module you may call, and `Host.Code.print_policy()` shows what your
  code may not. A refused call comes back as an error saying what to
  use instead. The `Host.*` modules are the stdlib: files, key/value
  state, the agent database and its migrations, pubsub and the web
  surface. Each one's docs carry the conventions for its area.

  Worth knowing before the first call:
  - Each `eval` starts with fresh bindings; nothing carries over from
    an earlier call except what you defined or stored.
  - The `print_*` functions print for you to read and return `:ok`.
    Several fit in one `eval`.
  - Ecto's query builders are macros: put `import Ecto.Query` at the
    top of any eval or module that queries.
  - Other agents, and earlier sessions, have built on your beamlet.
    Read what exists before building, and
    `Host.Code.print_outline(Module)` then `print_source` before
    replacing or patching a module.
  - Verify before reporting done: call a mounted route with
    `Host.Router.call(verb, path)`, query the rows you wrote.
  """

  @impl true
  def init(_client_info, frame), do: {:ok, frame}

  @doc """
  The instructions a client receives on `initialize`, written for the
  model.
  """
  @impl true
  def server_instructions, do: @instructions

  # Anubis generates its own handle_request/2 after this module's body,
  # so there is no super to call: each clause dispatches to the same
  # handler the generated one would. The listing goes to the tools
  # handler directly, whose spec knows the reply is a map. A call is
  # gated in each tool's execute instead (authorize/2).
  @impl true
  def handle_request(%{"method" => "tools/list"} = request, frame) do
    case Handlers.Tools.handle_list(request, frame, __MODULE__) do
      {:reply, %{"tools" => tools} = result, frame} ->
        {:reply, %{result | "tools" => Enum.filter(tools, &granted?(frame, &1.name))}, frame}

      other ->
        other
    end
  end

  def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

  # Anubis runs a task-augmented tools/call without passing through
  # handle_request/2, so the gate sits where every path ends: the
  # tool's execute. The refusal is the one Anubis gives for a tool it
  # does not have, since to this token it does not.
  @doc false
  @spec authorize(String.t(), Anubis.Server.Frame.t()) ::
          :ok | {:error, Error.t(), Anubis.Server.Frame.t()}
  def authorize(name, frame) do
    if granted?(frame, name),
      do: :ok,
      else:
        {:error, Error.protocol(:invalid_params, %{message: "Tool not found: #{name}"}), frame}
  end

  @doc false
  @spec seconds(pos_integer()) :: String.t()
  def seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)} seconds"
  def seconds(ms), do: "#{ms}ms"

  # The plug has already refused a token whose policy is not declared.
  defp granted?(frame, name) do
    {:ok, policy} = Policies.fetch(frame.assigns.principal.policy)
    name in Enum.map(Policy.tool_list(policy), &Atom.to_string/1)
  end
end
