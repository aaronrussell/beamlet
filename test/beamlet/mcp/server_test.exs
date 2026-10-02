defmodule Beamlet.MCP.ServerTest do
  use Beamlet.Case

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Beamlet.MCP.Define
  alias Beamlet.MCP.Eval
  alias Beamlet.MCP.Patch
  alias Beamlet.MCP.Server
  alias Beamlet.MCPClient
  alias Beamlet.Tokens

  test "initialize returns the server info and instructions", %{token: token} do
    {_client, result} = MCPClient.initialize(token)

    assert result["serverInfo"]["name"] == "beamlet"
    assert result["instructions"] == Server.server_instructions()
  end

  test "lists define, eval and patch with their descriptions", %{token: token} do
    {client, _result} = MCPClient.initialize(token)
    tools = MCPClient.list_tools(client)

    assert Enum.map(tools, & &1["name"]) == ["define", "eval", "patch"]

    assert Enum.map(tools, & &1["description"]) ==
             [Define.description(), Eval.description(), Patch.description()]

    assert Enum.map(tools, & &1["inputSchema"]["required"]) ==
             [["modules"], ["code"], ["patches"]]
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

  test "an invalid byte in an error is replaced and the session lives on", %{token: token} do
    {client, _result} = MCPClient.initialize(token)

    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             MCPClient.call_tool(client, "eval", %{code: "raise <<255>>"})

    assert text =~ "(RuntimeError) \uFFFD"

    assert %{"isError" => false, "content" => [%{"text" => "=> 2"}]} =
             MCPClient.call_tool(client, "eval", %{code: "1 + 1"})
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
             MCPClient.call_tool(client, "define", %{modules: [%{code: code}]})

    assert text == "Defined #{ns}.Greeter (new)"
    assert File.exists?(Path.join(data_dir, "code/lib/#{Macro.underscore(ns)}/greeter.ex"))

    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => ~s|=> "hi"|}]} =
             MCPClient.call_tool(client, "eval", %{code: "#{ns}.Greeter.hi()"})

    assert %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "define", %{modules: [%{code: code}]})

    assert text =~ "already exists"

    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "define", %{modules: [%{code: code, replace: true}]})

    assert text == "Defined #{ns}.Greeter (replaced)\n  - unchanged"
  end

  test "patch edits a defined module and returns the summary", %{token: token} do
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

    assert %{"isError" => false} =
             MCPClient.call_tool(client, "define", %{modules: [%{code: code}]})

    patches = [
      %{
        module: "#{ns}.Greeter",
        select: "hi/0",
        replace: ~s|@doc "Says hello."\ndef hi, do: "hello"|
      }
    ]

    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "patch", %{patches: patches})

    assert text == "Patched #{ns}.Greeter\n  - changed hi/0"

    assert %{"isError" => false, "content" => [%{"type" => "text", "text" => ~s|=> "hello"|}]} =
             MCPClient.call_tool(client, "eval", %{code: "#{ns}.Greeter.hi()"})
  end

  test "a patch breaking the one-anchor, one-operation rule is an error result", %{
    token: token
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

    assert %{"isError" => false} =
             MCPClient.call_tool(client, "define", %{modules: [%{code: code}]})

    patches = [
      %{module: "#{ns}.Greeter", find: "x", select: "hi/0", replace: "y"},
      %{module: "#{ns}.Greeter", replace: "y"}
    ]

    assert %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "patch", %{patches: patches})

    assert text =~ "patch 1 has both find and select — one anchor per patch"
    assert text =~ "patch 2 has no anchor — one anchor per patch"
  end

  test "a define that fails the docs gate is an error result", %{token: token} do
    {client, _result} = MCPClient.initialize(token)

    assert %{"isError" => true, "content" => [%{"type" => "text", "text" => text}]} =
             MCPClient.call_tool(client, "define", %{modules: [%{code: "defmodule A do end"}]})

    assert text =~ "A is missing @moduledoc"
  end

  describe "cancel" do
    @tag policies: [probe: [allow: [Kernel, Process]]]
    @tag :capture_log
    test "stops the evaluation and its output device when the client cancels the request" do
      {:ok, token} = Tokens.create(name: "phone", policy: "probe")
      {client, _result} = MCPClient.initialize(token)
      Process.register(self(), :eval_probe)

      code = """
      send(:eval_probe, {:evaluating, self(), Process.group_leader()})

      receive do
      after
        60_000 -> :ok
      end
      """

      call =
        Task.async(fn ->
          MCPClient.rpc(client, "tools/call", %{name: "eval", arguments: %{code: code}}, id: 42)
        end)

      assert_receive {:evaluating, evaluating, device}, 5_000
      ref = Process.monitor(evaluating)
      device_ref = Process.monitor(device)

      assert MCPClient.notify(client, "notifications/cancelled", %{requestId: 42}).status == 202

      assert_receive {:DOWN, ^ref, :process, ^evaluating, :killed}, 5_000
      assert_receive {:DOWN, ^device_ref, :process, ^device, _reason}, 5_000
      assert %{"error" => %{"message" => message}} = JSON.decode!(Task.await(call).resp_body)
      assert message =~ "cancelled"
    end
  end

  describe "under a policy" do
    @tag policies: [restricted: [tools: [:eval]]]
    test "lists only the tools the policy grants" do
      {:ok, token} = Tokens.create(name: "phone", policy: "restricted")
      {client, _result} = MCPClient.initialize(token)

      assert Enum.map(MCPClient.list_tools(client), & &1["name"]) == ["eval"]
    end

    @tag policies: [writer: [tools: [:define]]]
    test "define is two tools in one, define and patch" do
      {:ok, token} = Tokens.create(name: "phone", policy: "writer")
      {client, _result} = MCPClient.initialize(token)

      assert Enum.map(MCPClient.list_tools(client), & &1["name"]) == ["define", "patch"]
    end

    @tag policies: [restricted: [tools: [:eval]]]
    @tag :capture_log
    test "a call to a tool the policy withholds is an unknown tool" do
      {:ok, token} = Tokens.create(name: "phone", policy: "restricted")
      {client, _result} = MCPClient.initialize(token)

      conn = MCPClient.rpc(client, "tools/call", %{name: "define", arguments: %{modules: []}})

      assert conn.status == 200

      assert %{"error" => %{"code" => -32602, "data" => %{"message" => "Tool not found: define"}}} =
               JSON.decode!(conn.resp_body)

      conn = MCPClient.rpc(client, "tools/call", %{name: "patch", arguments: %{patches: []}})

      assert %{"error" => %{"code" => -32602, "data" => %{"message" => "Tool not found: patch"}}} =
               JSON.decode!(conn.resp_body)

      assert %{"isError" => false} = MCPClient.call_tool(client, "eval", %{code: "1 + 1"})
    end

    @tag policies: [nothing: [tools: []]]
    test "each tool refuses a token its policy withholds it from, however it is reached" do
      {:ok, token} = Tokens.create(name: "phone", policy: "nothing")
      frame = Frame.new(%{principal: principal(token)})

      for {component, name, params} <- [
            {Define, "define", %{modules: []}},
            {Eval, "eval", %{code: "1 + 1"}},
            {Patch, "patch", %{patches: []}}
          ] do
        assert {:error, %Error{code: -32602, data: %{message: message}}, ^frame} =
                 component.execute(params, frame)

        assert message == "Tool not found: #{name}"
      end
    end

    @tag policies: [nothing: [tools: []]]
    test "a policy with no tools lists none" do
      {:ok, token} = Tokens.create(name: "phone", policy: "nothing")
      {client, _result} = MCPClient.initialize(token)

      assert MCPClient.list_tools(client) == []
    end
  end
end

defmodule Beamlet.MCP.BudgetTest do
  use ExUnit.Case, async: true

  alias Beamlet.MCP.Define
  alias Beamlet.MCP.Eval
  alias Beamlet.MCP.Patch
  alias Beamlet.MCP.Server
  alias Beamlet.Policy

  test "the server's tools are the ones the default policy lists" do
    assert Enum.map(Server.__components__(:tool), & &1.name) ==
             Enum.map(Policy.tool_list(Policy.default()), &Atom.to_string/1)
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
    assert byte_size(Patch.description()) <= @budget
  end
end
