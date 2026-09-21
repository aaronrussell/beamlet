defmodule Beamlet.MCP.Server do
  @moduledoc """
  A beamlet's MCP server: the `define` and `eval` tools over
  Streamable HTTP, for any MCP client.

  Runs as a child of `Beamlet`. A host serves it at `/beamlet/mcp` by
  forwarding to `Beamlet.Router`, which mounts the authenticating
  plug there, and every request then carries one of the beamlet's
  tokens (`Beamlet.MCP.Plug`):

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

  @instructions """
  These tools work on your beamlet: a running Elixir application you
  extend from the inside. They apply only when working on it.

  `eval` evaluates Elixir code on your beamlet and returns the
  result. `define`, when it is in your tool list, compiles module
  definitions into the running system and keeps them across
  restarts; anything worth calling again belongs in a module.

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
  - Your beamlet is shared with other users and agents. Read what
    exists before building, and `Host.Code.print_source(Module)`
    before replacing a module.
  - Verify before reporting done: call a mounted route with
    `Host.Router.call(verb, path)`, query the rows you wrote.
  """

  @impl true
  def init(_client_info, frame), do: {:ok, frame}

  @impl true
  def server_instructions, do: @instructions

  # Anubis generates its own handle_request/2 after this module's body,
  # so there is no super to call: each clause dispatches to the same
  # handler the generated one would. The listing goes to the tools
  # handler directly, whose spec knows the reply is a map.
  @impl true
  def handle_request(%{"method" => "tools/list"} = request, frame) do
    case Handlers.Tools.handle_list(request, frame, __MODULE__) do
      {:reply, %{"tools" => tools} = result, frame} ->
        {:reply, %{result | "tools" => Enum.filter(tools, &granted?(frame, &1.name))}, frame}

      other ->
        other
    end
  end

  def handle_request(%{"method" => "tools/call", "params" => %{"name" => name}} = request, frame) do
    if granted?(frame, name) do
      Handlers.handle(request, __MODULE__, frame)
    else
      {:error, Error.protocol(:invalid_params, %{message: "Tool not found: #{name}"}), frame}
    end
  end

  def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

  # The plug has already refused a token whose policy is not declared.
  defp granted?(frame, name) do
    {:ok, %Policy{tools: tools}} = Policies.fetch(frame.assigns.principal.policy)
    name in Enum.map(tools, &Atom.to_string/1)
  end
end
