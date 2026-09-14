defmodule Beamlet.MCP.ServerTest do
  use Beamlet.Case

  alias Beamlet.MCP.Define
  alias Beamlet.MCP.Eval
  alias Beamlet.MCP.Server
  alias Beamlet.MCPClient

  test "initialize returns the server info and instructions" do
    {_session_id, result} = MCPClient.initialize()

    assert result["serverInfo"]["name"] == "beamlet"
    assert result["instructions"] == Server.server_instructions()
  end

  test "lists define and eval with their descriptions" do
    {session_id, _result} = MCPClient.initialize()
    tools = MCPClient.list_tools(session_id)

    assert Enum.map(tools, & &1["name"]) == ["define", "eval"]
    assert Enum.map(tools, & &1["description"]) == [Define.description(), Eval.description()]
    assert Enum.map(tools, & &1["inputSchema"]["required"]) == [["code"], ["code"]]
  end

  test "the stub tools answer with an error result" do
    {session_id, _result} = MCPClient.initialize()

    assert %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(session_id, "eval", %{code: "1 + 1"})

    assert text =~ "not available yet"
  end
end

defmodule Beamlet.MCP.BudgetTest do
  use ExUnit.Case, async: true

  alias Beamlet.MCP.Define
  alias Beamlet.MCP.Eval
  alias Beamlet.MCP.Server

  # Claude Code truncates server instructions and each tool
  # description at 2KB: 2,048 characters, measured in the MCP spike.
  # Bytes are the conservative measure, equal for ASCII and larger
  # for anything else.
  @budget 2048

  test "server instructions fit Claude Code's 2KB cut" do
    assert byte_size(Server.server_instructions()) <= @budget
  end

  test "tool descriptions fits Claude Code's 2KB cut" do
    assert byte_size(Define.description()) <= @budget
    assert byte_size(Eval.description()) <= @budget
  end
end
