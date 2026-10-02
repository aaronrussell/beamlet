defmodule Beamlet.MCP.PlugTest do
  use Beamlet.Case, shared: true

  import Plug.Conn
  import Plug.Test

  alias Beamlet.MCPClient
  alias Beamlet.Principal
  alias Beamlet.Tokens

  @plug_opts Beamlet.MCP.Plug.init([])
  @challenge ~s(Bearer realm="beamlet", ) <>
               ~s(resource_metadata="http://localhost:4000/.well-known/oauth-protected-resource")

  test "a request with no token is a 401 whose challenge names the metadata document" do
    conn = MCPClient.rpc(nil, "tools/list", %{})

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [@challenge]
    assert conn.resp_body =~ "Authorization: Bearer <token>"
  end

  test "another scheme is a 401" do
    assert unauthorized?(request("Basic YWxpY2U6c2VjcmV0"))
  end

  test "the scheme matches in any case", %{token: token} do
    assert request("bearer " <> token.secret).status == 200
    assert request("BEARER " <> token.secret).status == 200
  end

  test "a secret matching no token is a 401" do
    assert unauthorized?(request("Bearer " <> Base.url_encode64(:crypto.strong_rand_bytes(32))))
  end

  test "a deleted token's secret is a 401", %{token: token} do
    {:ok, _} = Tokens.delete(token)
    assert unauthorized?(request("Bearer " <> token.secret))
  end

  test "an expired oauth token's secret is a 401" do
    now = DateTime.utc_now()

    {:ok, expired} =
      Tokens.create(
        kind: :oauth,
        client: "https://claude.ai/client.json",
        expires_at: DateTime.add(now, -1, :second),
        refresh_expires_at: DateTime.add(now, 3600, :second)
      )

    {:ok, live} =
      Tokens.create(
        kind: :oauth,
        client: "https://claude.ai/client.json",
        expires_at: DateTime.add(now, 3600, :second),
        refresh_expires_at: DateTime.add(now, 7200, :second)
      )

    assert unauthorized?(request("Bearer " <> expired.secret))
    assert request("Bearer " <> live.secret).status == 200
  end

  test "a GET with no token is a 401" do
    conn = :get |> conn("/") |> Beamlet.MCP.Plug.call(@plug_opts)
    assert conn.status == 401
  end

  test "a token naming an undeclared policy is a 403 naming both", %{token: token} do
    # The changeset refuses to create such a token, so this stands in
    # for a policy removed from config between restarts.
    import Ecto.Query

    Beamlet.Repo.update_all(from(t in Beamlet.Token, where: t.id == ^token.id),
      set: [policy: "gone"]
    )

    conn = request("Bearer " <> token.secret)
    assert conn.status == 403
    assert get_resp_header(conn, "www-authenticate") == []
    assert conn.resp_body == "Token test names policy gone, which this beamlet does not declare."

    conn =
      :get
      |> conn("/")
      |> put_req_header("authorization", "Bearer " <> token.secret)
      |> Beamlet.MCP.Plug.call(@plug_opts)

    assert conn.status == 403
  end

  test "a valid token reaches the server with the principal in assigns", %{token: token} do
    conn = MCPClient.rpc(%MCPClient{secret: token.secret}, "initialize", initialize_params())

    assert conn.status == 200
    {:ok, authenticated} = Tokens.authenticate(token.secret)
    assert conn.assigns.principal == Principal.from_token(authenticated)
  end

  @tag :capture_log
  test "the transport waits the configured request timeout, read per request", %{token: token} do
    {client, _result} = MCPClient.initialize(token)
    Application.put_env(:beamlet, :mcp, request_timeout: 200)
    on_exit(fn -> Application.delete_env(:beamlet, :mcp) end)

    code = """
    receive do
    after
      2_000 -> :ok
    end
    """

    conn = MCPClient.rpc(client, "tools/call", %{name: "eval", arguments: %{code: code}})

    assert %{"error" => %{"data" => %{"message" => "Server unavailable"}}} =
             JSON.decode!(conn.resp_body)
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
    conn.status == 401 and get_resp_header(conn, "www-authenticate") == [@challenge]
  end

  defp initialize_params do
    %{protocolVersion: "2025-06-18", capabilities: %{}, clientInfo: %{name: "test", version: "0"}}
  end
end
