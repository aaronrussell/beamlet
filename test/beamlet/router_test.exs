defmodule Beamlet.RouterTest do
  use Beamlet.Case

  import Phoenix.ConnTest
  import Plug.Conn

  setup do
    %{conn: build_conn()}
  end

  test "the MCP server is served at /beamlet/mcp and asks for a token", %{conn: conn} do
    conn =
      conn |> put_req_header("content-type", "application/json") |> post("/beamlet/mcp", "{}")

    assert conn.status == 401

    assert get_resp_header(conn, "www-authenticate") == [
             ~s(Bearer realm="beamlet", ) <>
               ~s(resource_metadata="http://localhost:4000/.well-known/oauth-protected-resource")
           ]

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
      |> post("/beamlet/mcp", JSON.encode!(initialize))

    assert conn.status == 200
    [_line, data] = Regex.run(~r/^data: (.*)$/m, conn.resp_body)
    assert %{"result" => %{"serverInfo" => %{"name" => "beamlet"}}} = JSON.decode!(data)
  end

  test "the beamlet's own pages are under /beamlet, behind the login", %{conn: conn} do
    assert redirected_to(get(conn, "/beamlet")) == "/beamlet/login"
    assert conn |> get("/beamlet/login") |> html_response(200) =~ "Sign in"
  end

  test "no agent route answers under /beamlet, whatever the table holds", %{
    conn: conn,
    token: token
  } do
    %{hello: hello, echo: echo} = Beamlet.RouteFixtures.define!(principal(token))

    for {kind, verb, path, module, action} <- [
          {:live_view, :get, "/:a/:b", hello, nil},
          {:live_view, :get, "//beamlet/admin", hello, nil},
          {:controller, :post, "/*rest", echo, "plain"}
        ] do
      {:ok, _route} =
        Beamlet.Routes.create(%{
          kind: kind,
          verb: verb,
          path: path,
          module: module,
          action: action,
          principal: principal(token)
        })
    end

    assert :ok = Beamlet.Routes.regenerate()
    assert conn |> get("/x/y") |> html_response(200) =~ "hello from HelloLive"
    assert conn |> post("/elsewhere") |> response(200) == "plain"

    assert conn |> get("/beamlet/logout") |> response(404)
    assert conn |> get("/beamlet/admin") |> response(404)
    assert conn |> post("/beamlet") |> response(404)
    assert conn |> post("/beamlet/anything/else") |> response(404)
  end

  test "the root is an agent's: a plain 404 until one mounts it", %{
    conn: conn,
    token: token
  } do
    assert conn |> get("/") |> response(404) == "Not Found"

    %{hello: hello} = Beamlet.RouteFixtures.define!(principal(token))

    {:ok, _route} =
      Beamlet.Routes.create(%{
        kind: :live_view,
        path: "/",
        module: hello,
        principal: principal(token)
      })

    assert :ok = Beamlet.Routes.regenerate()
    assert conn |> get("/") |> html_response(200) =~ "hello from HelloLive"
  end
end
