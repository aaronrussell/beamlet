defmodule Beamlet.MCP.Server do
  @moduledoc """
  A beamlet's MCP server: the `define` and `eval` tools over
  Streamable HTTP, for any MCP client.

  Runs as a child of `Beamlet`. A host serves it at `/_mcp` by
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
  This is your beamlet: a running Elixir application you extend from
  the inside. Two tools. `eval` evaluates Elixir code and returns the
  result; `define` compiles module definitions into the running
  system and keeps them across restarts.

  Start with `eval`: `Host.Code.print_modules()` lists what has been
  defined on this beamlet and `Host.Code.print_policy()` what your
  code may call. A refused call comes back as an error saying what
  to use instead.
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
