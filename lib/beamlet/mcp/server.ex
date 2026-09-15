defmodule Beamlet.MCP.Server do
  @moduledoc """
  A beamlet's MCP server: the `define` and `eval` tools over
  Streamable HTTP, for any MCP client.

  Runs as a child of `Beamlet`. A host serves it by mounting the
  authenticating plug, and every request then carries one of the
  beamlet's tokens (`Beamlet.MCP.Plug`):

      forward "/mcp", Beamlet.MCP.Plug

  The instructions returned on `initialize` and each tool's
  description are kept under 2,048 bytes: Claude Code truncates both
  at 2KB, so they say what matters most first and point at the
  stdlib for the rest.
  """

  @version Mix.Project.config()[:version]

  use Anubis.Server, name: "beamlet", version: @version, capabilities: [:tools]

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
end
