defmodule Beamlet.RouterTest do
  use Beamlet.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  setup do
    %{conn: build_conn()}
  end

  test "the MCP server is served at /_mcp and asks for a token", %{conn: conn} do
    conn = conn |> put_req_header("content-type", "application/json") |> post("/_mcp", "{}")

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    assert conn.resp_body =~ "A beamlet token is required"
  end

  test "a request with a token reaches the MCP server", %{conn: conn, token: token} do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "0"}
      }
    }

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token.secret}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/_mcp", JSON.encode!(initialize))

    assert conn.status == 200
    assert conn.resp_body =~ "beamlet"
  end

  test "the host's own routes come first", %{conn: conn} do
    assert conn |> get("/host/ping") |> response(200) == "pong"
  end

  test "everything else is the generated router, empty at first", %{conn: conn} do
    assert conn |> get("/nowhere") |> response(404)
  end
end
