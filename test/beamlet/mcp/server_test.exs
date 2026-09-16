defmodule Beamlet.MCP.ServerTest do
  # The define test loads a module into the VM.
  use Beamlet.Case, async: false

  alias Beamlet.MCP.Define
  alias Beamlet.MCP.Eval
  alias Beamlet.MCP.Server
  alias Beamlet.MCPClient
  alias Beamlet.Users

  test "initialize returns the server info and instructions", %{token: token} do
    {_client, result} = MCPClient.initialize(token)

    assert result["serverInfo"]["name"] == "beamlet"
    assert result["instructions"] == Server.server_instructions()
  end

  test "lists define and eval with their descriptions", %{token: token} do
    {client, _result} = MCPClient.initialize(token)
    tools = MCPClient.list_tools(client)

    assert Enum.map(tools, & &1["name"]) == ["define", "eval"]
    assert Enum.map(tools, & &1["description"]) == [Define.description(), Eval.description()]
    assert Enum.map(tools, & &1["inputSchema"]["required"]) == [["code"], ["code"]]
  end

  test "eval evaluates and returns the inspected result", %{token: token} do
    {client, _result} = MCPClient.initialize(token)

    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => "=> 2"}]} =
             MCPClient.call_tool(client, "eval", %{code: "1 + 1"})
  end

  test "a policy rejection is an error tool result", %{token: token} do
    {client, _result} = MCPClient.initialize(token)

    assert %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "eval", %{code: ~s|System.cmd("ls", [])|})

    assert text =~ "System.cmd"
  end

  test "define compiles the module, writes its source and returns the summary", %{
    token: token,
    data_dir: data_dir
  } do
    {client, _result} = MCPClient.initialize(token)
    ns = unique_namespace()
    purge_on_exit([Module.concat([ns, Greeter])])

    code = """
    defmodule #{ns}.Greeter do
      @moduledoc "Greets."

      @doc "Says hi."
      def hi, do: "hi"
    end
    """

    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "define", %{code: code})

    assert text == "Defined #{ns}.Greeter (new)"
    assert File.exists?(Path.join(data_dir, "code/lib/#{Macro.underscore(ns)}/greeter.ex"))

    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => ~s|=> "hi"|}]} =
             MCPClient.call_tool(client, "eval", %{code: "#{ns}.Greeter.hi()"})

    assert %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "define", %{code: code})

    assert text =~ "already exists"

    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "define", %{code: code, replace: true})

    assert text == "Defined #{ns}.Greeter (replaced)"
  end

  test "a define that fails the docs gate is an error result", %{token: token} do
    {client, _result} = MCPClient.initialize(token)

    assert %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "define", %{code: "defmodule A do end"})

    assert text =~ "A is missing @moduledoc"
  end

  describe "cancel" do
    @tag policies: [probe: [allow: [Kernel]]]
    @tag :capture_log
    test "stops the evaluation when the client cancels the request", %{user: user} do
      {:ok, token} = Users.create_token(user, name: "phone", policy: "probe")
      {client, _result} = MCPClient.initialize(token)
      Process.register(self(), :eval_probe)

      code = """
      send(:eval_probe, self())

      receive do
      after
        60_000 -> :ok
      end
      """

      call =
        Task.async(fn ->
          MCPClient.rpc(client, "tools/call", %{name: "eval", arguments: %{code: code}}, id: 42)
        end)

      assert_receive evaluating when is_pid(evaluating), 5_000
      ref = Process.monitor(evaluating)

      assert MCPClient.notify(client, "notifications/cancelled", %{requestId: 42}).status == 202

      assert_receive {:DOWN, ^ref, :process, ^evaluating, :killed}, 5_000
      assert %{"error" => %{"message" => message}} = JSON.decode!(Task.await(call).resp_body)
      assert message =~ "cancelled"
    end
  end

  describe "under a policy" do
    @tag policies: [restricted: [tools: [:eval]]]
    test "lists only the tools the policy grants", %{user: user} do
      {:ok, token} = Users.create_token(user, name: "phone", policy: "restricted")
      {client, _result} = MCPClient.initialize(token)

      assert Enum.map(MCPClient.list_tools(client), & &1["name"]) == ["eval"]
    end

    @tag policies: [restricted: [tools: [:eval]]]
    @tag :capture_log
    test "a call to a tool the policy withholds is an unknown tool", %{user: user} do
      {:ok, token} = Users.create_token(user, name: "phone", policy: "restricted")
      {client, _result} = MCPClient.initialize(token)

      conn = MCPClient.rpc(client, "tools/call", %{name: "define", arguments: %{code: ""}})

      assert conn.status == 200

      assert %{"error" => %{"code" => -32602, "data" => %{"message" => "Tool not found: define"}}} =
               JSON.decode!(conn.resp_body)

      assert %{"isError" => false} = MCPClient.call_tool(client, "eval", %{code: "1 + 1"})
    end

    @tag policies: [nothing: [tools: []]]
    test "a policy with no tools lists none", %{user: user} do
      {:ok, token} = Users.create_token(user, name: "phone", policy: "nothing")
      {client, _result} = MCPClient.initialize(token)

      assert MCPClient.list_tools(client) == []
    end
  end
end

defmodule Beamlet.MCP.BudgetTest do
  use ExUnit.Case, async: true

  alias Beamlet.MCP.Define
  alias Beamlet.MCP.Eval
  alias Beamlet.MCP.Server

  test "the server's tools are the ones a policy can grant" do
    assert Enum.map(Server.__components__(:tool), & &1.name) ==
             Enum.map(Beamlet.Policy.tools(), &Atom.to_string/1)
  end

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
