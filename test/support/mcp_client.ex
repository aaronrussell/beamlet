defmodule Beamlet.MCPClient do
  @moduledoc """
  A minimal MCP client for tests: JSON-RPC over the Streamable HTTP
  plug with `Plug.Test`, no endpoint.

  `initialize/0` does the handshake and returns the session id every
  later request needs.
  """

  import ExUnit.Assertions
  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Transport.StreamableHTTP

  @plug_opts StreamableHTTP.Plug.init(server: Beamlet.MCP.Server)
  @session_header "mcp-session-id"
  @protocol_version "2025-06-18"

  @doc "Initializes a session; returns its id and the initialize result."
  @spec initialize() :: {String.t(), map()}
  def initialize do
    conn =
      rpc(nil, "initialize", %{
        protocolVersion: @protocol_version,
        capabilities: %{},
        clientInfo: %{name: "test", version: "0"}
      })

    [session_id] = get_resp_header(conn, @session_header)
    result = result(conn)
    assert notify(session_id, "notifications/initialized").status == 202
    {session_id, result}
  end

  @doc "Lists the server's tools."
  @spec list_tools(String.t()) :: [map()]
  def list_tools(session_id) do
    %{"tools" => tools} = session_id |> rpc("tools/list", %{}) |> result()
    tools
  end

  @doc "Calls a tool; returns the tool result."
  @spec call_tool(String.t(), String.t(), map()) :: map()
  def call_tool(session_id, name, arguments) do
    session_id |> rpc("tools/call", %{name: name, arguments: arguments}) |> result()
  end

  @doc "Sends one JSON-RPC request and returns the conn."
  @spec rpc(String.t() | nil, String.t(), map()) :: Plug.Conn.t()
  def rpc(session_id, method, params) do
    id = System.unique_integer([:positive])
    post(session_id, %{jsonrpc: "2.0", id: id, method: method, params: params})
  end

  defp notify(session_id, method), do: post(session_id, %{jsonrpc: "2.0", method: method})

  defp post(session_id, body) do
    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_session_header(session_id)
    |> StreamableHTTP.Plug.call(@plug_opts)
  end

  defp put_session_header(conn, nil), do: conn
  defp put_session_header(conn, session_id), do: put_req_header(conn, @session_header, session_id)

  defp result(conn) do
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
    assert %{"result" => result} = JSON.decode!(conn.resp_body)
    result
  end
end
