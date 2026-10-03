defmodule Beamlet.OAuth.TokenControllerTest do
  use Beamlet.Case, shared: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias Beamlet.MCPClient
  alias Beamlet.OAuth.Clients
  alias Beamlet.Token
  alias Beamlet.Tokens

  @client_id "https://chat.example/client.json"
  @redirect_uri "https://chat.example/callback"
  @document %{"client_id" => @client_id, "redirect_uris" => [@redirect_uri]}
  @resource "http://localhost:4000/beamlet/mcp"

  setup do
    Req.Test.stub(Clients, fn conn -> Req.Test.json(conn, @document) end)
    %{conn: sign_in(build_conn())}
  end

  # The browser half of the flow: consent as the signed-in owner and
  # read the code off the redirect. Returns the code and the verifier
  # whose hash the code was issued against.
  defp authorize(conn, overrides \\ %{}) do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    {decision, request} =
      %{
        client_id: @client_id,
        redirect_uri: @redirect_uri,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256",
        resource: @resource,
        decision: "allow",
        policy: "default"
      }
      |> Map.merge(overrides)
      |> Map.split([:decision, :policy])

    {:ok, view, _html} = live(conn, "/beamlet/authorize?" <> URI.encode_query(request))

    {:error, {:redirect, %{to: location}}} =
      view
      |> element("#consent-form")
      |> render_submit(%{"decision" => decision.decision, "policy" => decision.policy})

    %{"code" => code} = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {code, verifier}
  end

  # The client half: a form-encoded post with no session and no CSRF
  # token, as a client sends it, so the endpoint must sit outside the
  # forgery protection.
  defp token_request(params) do
    build_conn()
    |> put_private(:plug_skip_csrf_protection, false)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/beamlet/token", URI.encode_query(params))
  end

  defp exchange(code, verifier, overrides \\ %{}) do
    token_request(
      Map.merge(
        %{
          grant_type: "authorization_code",
          code: code,
          client_id: @client_id,
          redirect_uri: @redirect_uri,
          code_verifier: verifier,
          resource: @resource
        },
        overrides
      )
    )
  end

  defp refresh(refresh_token, overrides \\ %{}) do
    token_request(
      Map.merge(
        %{grant_type: "refresh_token", refresh_token: refresh_token, client_id: @client_id},
        overrides
      )
    )
  end

  defp assert_error(conn, error) do
    assert %{"error" => ^error, "error_description" => description} = json_response(conn, 400)
    assert is_binary(description)
    description
  end

  describe "grant_type=authorization_code" do
    test "redeems a code for a token that works at the MCP endpoint", %{conn: conn} do
      {code, verifier} = authorize(conn)
      conn = exchange(code, verifier)

      assert %{
               "access_token" => access,
               "token_type" => "Bearer",
               "expires_in" => 86_400,
               "refresh_token" => refresh
             } = reply = json_response(conn, 200)

      refute Map.has_key?(reply, "scope")
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      {client, _result} = MCPClient.initialize(%Token{secret: access})
      assert Enum.map(MCPClient.list_tools(client), & &1["name"]) == ["define", "eval", "patch"]

      assert [%Token{kind: :cli}, %Token{kind: :oauth} = token] = Tokens.list()
      assert token.client == @client_id
      assert token.policy == "default"
      assert Token.label(token) == "chat.example"
      assert DateTime.diff(token.expires_at, DateTime.utc_now()) in 86_390..86_400
      assert DateTime.diff(token.refresh_expires_at, DateTime.utc_now()) in 2_591_990..2_592_000
      assert {:ok, %Token{id: id}} = Tokens.authenticate_refresh(refresh)
      assert id == token.id
    end

    @tag policies: [explorer: [tools: [:eval]]]
    test "the token carries the consented policy and the reply echoes the scope", %{conn: conn} do
      {code, verifier} = authorize(conn, %{policy: "explorer", scope: "offline_access"})

      assert %{"access_token" => access, "scope" => "offline_access"} =
               code |> exchange(verifier) |> json_response(200)

      {client, _result} = MCPClient.initialize(%Token{secret: access})
      assert Enum.map(MCPClient.list_tools(client), & &1["name"]) == ["eval"]
    end

    test "a wrong verifier is invalid_grant and burns the code", %{conn: conn} do
      {code, verifier} = authorize(conn)

      assert code |> exchange("not-the-verifier") |> assert_error("invalid_grant") =~
               "code_verifier"

      assert code |> exchange(verifier) |> assert_error("invalid_grant") =~
               "unknown, already used"
    end

    test "a code is single use", %{conn: conn} do
      {code, verifier} = authorize(conn)
      assert code |> exchange(verifier) |> json_response(200)
      assert code |> exchange(verifier) |> assert_error("invalid_grant") =~ "already used"
    end

    test "the client id, redirect URI and resource must be the ones the code was issued for", %{
      conn: conn
    } do
      mismatches = [
        {%{client_id: "https://other.example/client.json"}, "another client"},
        {%{redirect_uri: "https://chat.example/other"}, "redirect_uri"},
        {%{resource: "http://localhost:4000/other"}, "resource"}
      ]

      for {overrides, hint} <- mismatches do
        {code, verifier} = authorize(conn)
        assert code |> exchange(verifier, overrides) |> assert_error("invalid_grant") =~ hint
      end
    end

    test "resource may be omitted at the exchange", %{conn: conn} do
      {code, verifier} = authorize(conn)
      assert code |> exchange(verifier, %{resource: ""}) |> json_response(200)
    end

    test "resource may be named only at the exchange, and only as this beamlet's", %{conn: conn} do
      {code, verifier} = authorize(conn, %{resource: ""})
      assert code |> exchange(verifier) |> json_response(200)

      {code, verifier} = authorize(conn, %{resource: ""})

      assert code
             |> exchange(verifier, %{resource: "http://localhost:4000/other"})
             |> assert_error("invalid_grant") =~ "resource"
    end

    test "a code for a policy no longer declared is invalid_grant and mints nothing" do
      verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      code =
        Beamlet.OAuth.Codes.store(%{
          policy: "retired",
          client_id: @client_id,
          redirect_uri: @redirect_uri,
          code_challenge: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
          resource: @resource,
          scope: nil
        })

      before = Tokens.list()
      assert code |> exchange(verifier) |> assert_error("invalid_grant") =~ "no longer declared"
      assert Tokens.list() == before
    end

    test "missing fields are invalid_request naming them", %{conn: conn} do
      {code, _verifier} = authorize(conn)
      conn = token_request(%{grant_type: "authorization_code", code: code})

      description = assert_error(conn, "invalid_request")
      for field <- ~w(client_id redirect_uri code_verifier), do: assert(description =~ field)
    end
  end

  describe "grant_type=refresh_token" do
    setup %{conn: conn} do
      {code, verifier} = authorize(conn)

      %{"access_token" => access, "refresh_token" => refresh} =
        code |> exchange(verifier) |> json_response(200)

      {:ok, %Token{id: id}} = Tokens.authenticate(access)
      %{access: access, refresh: refresh, id: id}
    end

    test "rotates the token in place: a new pair, the old one dead, the id unchanged", %{
      access: access,
      refresh: refresh,
      id: id
    } do
      conn = refresh(refresh)

      assert %{
               "access_token" => new_access,
               "token_type" => "Bearer",
               "expires_in" => 86_400,
               "refresh_token" => new_refresh
             } = reply = json_response(conn, 200)

      refute Map.has_key?(reply, "scope")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert new_access != access and new_refresh != refresh

      assert {:ok, %Token{id: ^id}} = Tokens.authenticate(new_access)
      assert {:ok, %Token{id: ^id}} = Tokens.authenticate_refresh(new_refresh)
      assert {:error, :unknown_token} = Tokens.authenticate(access)
      assert refresh |> refresh() |> assert_error("invalid_grant") =~ "unknown or already used"
    end

    test "the client id must be the token's", %{refresh: refresh} do
      conn = refresh(refresh, %{client_id: "https://other.example/client.json"})
      assert assert_error(conn, "invalid_grant") =~ "another client"
    end

    test "an expired refresh token is invalid_grant" do
      now = DateTime.utc_now(:second)

      {:ok, token} =
        Tokens.create(
          kind: :oauth,
          client: @client_id,
          expires_at: DateTime.add(now, 3600, :second),
          refresh_expires_at: DateTime.add(now, -1, :second)
        )

      assert token.refresh_secret |> refresh() |> assert_error("invalid_grant") =~ "expired"
    end

    test "a cli token's secret, or any other string, is invalid_grant", %{token: token} do
      assert token.secret |> refresh() |> assert_error("invalid_grant") =~ "unknown"
      assert "nonsense" |> refresh() |> assert_error("invalid_grant") =~ "unknown"
    end

    test "missing fields are invalid_request", %{refresh: refresh} do
      conn = token_request(%{grant_type: "refresh_token", refresh_token: refresh})
      assert assert_error(conn, "invalid_request") =~ "client_id"
    end
  end

  test "any other grant type is unsupported_grant_type" do
    assert %{grant_type: "password"} |> token_request() |> assert_error("unsupported_grant_type")
    assert %{} |> token_request() |> assert_error("unsupported_grant_type")
  end
end
