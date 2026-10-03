defmodule Beamlet.MCP.Server do
  @moduledoc """
  A beamlet's MCP server: the `define`, `eval` and `patch` tools over
  Streamable HTTP, for any MCP client.

  The tools are `Beamlet.MCP.Define`, `Beamlet.MCP.Eval` and
  `Beamlet.MCP.Patch`. The server runs as a child of `Beamlet`. A
  host serves it at `/beamlet/mcp` by forwarding to `Beamlet.Router`,
  which mounts the authenticating plug there, so every request
  carries one of the beamlet's tokens as a bearer credential:

      forward "/", Beamlet.Router

  What a token sees is set by its policy (`Beamlet.Policy`): the
  listing holds only the tools the policy grants, and a call to any
  other tool is refused as unknown, since to that token it is. The
  listing is filtered per request; a policy change is a restart, so
  no list-changed notification is sent.

  The instructions returned on `initialize` and each tool's
  description are kept under 2,048 bytes: Claude Code truncates both
  at 2KB, so they say what matters most first and point at the
  stdlib for the rest.
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
