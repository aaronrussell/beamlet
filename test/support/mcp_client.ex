defmodule Beamlet.MCPClient do
  @moduledoc """
  A minimal MCP client for tests: JSON-RPC through `Beamlet.MCP.Plug`
  with `Plug.Test`, no endpoint.

  `initialize/1` takes a token, does the handshake and returns a
  client carrying the session id and the secret, since every request
  sends both. `rpc/3` with `nil` sends neither, for tests of the
  unauthenticated path.
  """

  import ExUnit.Assertions
  import Plug.Conn
  import Plug.Test

  alias Beamlet.Token

  defstruct [:session_id, :secret]

  @typedoc "An initialized client: the session and the secret it authenticates with."
  @type t :: %__MODULE__{session_id: String.t() | nil, secret: String.t() | nil}

  @plug_opts Beamlet.MCP.Plug.init([])
  @session_header "mcp-session-id"
  @protocol_version "2025-06-18"

  @doc "Initializes a session with the token's secret; returns the client and the initialize result."
  @spec initialize(Token.t()) :: {t(), map()}
  def initialize(%Token{secret: secret}) when is_binary(secret) do
    conn =
      rpc(%__MODULE__{secret: secret}, "initialize", %{
        protocolVersion: @protocol_version,
        capabilities: %{},
        clientInfo: %{name: "test", version: "0"}
      })

    [session_id] = get_resp_header(conn, @session_header)
    result = result(conn)
    client = %__MODULE__{session_id: session_id, secret: secret}
    assert notify(client, "notifications/initialized").status == 202
    {client, result}
  end

  @doc "Lists the server's tools."
  @spec list_tools(t()) :: [map()]
  def list_tools(%__MODULE__{} = client) do
    %{"tools" => tools} = client |> rpc("tools/list", %{}) |> result()
    tools
  end

  @doc "Calls a tool; returns the tool result."
  @spec call_tool(t(), String.t(), map()) :: map()
  def call_tool(%__MODULE__{} = client, name, arguments) do
    client |> rpc("tools/call", %{name: name, arguments: arguments}) |> result()
  end

  @doc "Sends one JSON-RPC request and returns the conn."
  @spec rpc(t() | nil, String.t(), map()) :: Plug.Conn.t()
  def rpc(client, method, params) do
    id = System.unique_integer([:positive])
    post(client, %{jsonrpc: "2.0", id: id, method: method, params: params})
  end

  defp notify(client, method), do: post(client, %{jsonrpc: "2.0", method: method})

  defp post(client, body) do
    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_client_headers(client)
    |> Beamlet.MCP.Plug.call(@plug_opts)
  end

  defp put_client_headers(conn, nil), do: conn

  defp put_client_headers(conn, %__MODULE__{session_id: session_id, secret: secret}) do
    conn
    |> put_optional_header(@session_header, session_id)
    |> put_optional_header("authorization", secret && "Bearer #{secret}")
  end

  defp put_optional_header(conn, _name, nil), do: conn
  defp put_optional_header(conn, name, value), do: put_req_header(conn, name, value)

  defp result(conn) do
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
    assert %{"result" => result} = JSON.decode!(conn.resp_body)
    result
  end
end
