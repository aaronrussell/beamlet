defmodule Beamlet.MCP.PlugTest do
  use Beamlet.Case

  import Plug.Conn
  import Plug.Test

  alias Beamlet.MCPClient
  alias Beamlet.Principal
  alias Beamlet.Users

  @plug_opts Beamlet.MCP.Plug.init([])

  test "a request with no token is a 401 with a Bearer challenge" do
    conn = MCPClient.rpc(nil, "tools/list", %{})

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    assert conn.resp_body =~ "Authorization: Bearer <token>"
  end

  test "another scheme is a 401" do
    assert unauthorized?(request("Basic YWxpY2U6c2VjcmV0"))
  end

  test "a secret matching no token is a 401" do
    assert unauthorized?(request("Bearer " <> Base.url_encode64(:crypto.strong_rand_bytes(32))))
  end

  test "a deleted token's secret is a 401", %{token: token} do
    {:ok, _} = Users.delete_token(token)
    assert unauthorized?(request("Bearer " <> token.secret))
  end

  test "a GET with no token is a 401" do
    conn = :get |> conn("/") |> Beamlet.MCP.Plug.call(@plug_opts)
    assert conn.status == 401
  end

  test "a valid token reaches the server with the principal in assigns", %{token: token} do
    conn = MCPClient.rpc(%MCPClient{secret: token.secret}, "initialize", initialize_params())

    assert conn.status == 200
    {:ok, authenticated} = Users.authenticate(token.secret)
    assert conn.assigns.principal == Principal.from_token(authenticated)
  end

  defp request(authorization) do
    :post
    |> conn(
      "/",
      JSON.encode!(%{jsonrpc: "2.0", id: 1, method: "initialize", params: initialize_params()})
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", authorization)
    |> Beamlet.MCP.Plug.call(@plug_opts)
  end

  defp unauthorized?(conn) do
    conn.status == 401 and get_resp_header(conn, "www-authenticate") == ["Bearer"]
  end

  defp initialize_params do
    %{protocolVersion: "2025-06-18", capabilities: %{}, clientInfo: %{name: "test", version: "0"}}
  end
end
