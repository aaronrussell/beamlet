defmodule Beamlet.OAuth.AuthorizeControllerTest do
  use Beamlet.Case

  @moduletag :capture_log

  import Phoenix.ConnTest
  import Plug.Conn

  alias Beamlet.OAuth.Clients
  alias Beamlet.OAuth.Codes
  alias Beamlet.Users

  @client_id "https://chat.example/client.json"
  @redirect_uri "https://chat.example/callback"
  @document %{
    "client_id" => @client_id,
    "redirect_uris" => [
      @redirect_uri,
      "http://localhost/callback",
      "https://chat.example/cb?app=1",
      "chat-app://oauth/callback"
    ]
  }
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  @iss "http://localhost:4000"

  setup %{user: user} do
    Req.Test.stub(Clients, fn conn -> Req.Test.json(conn, @document) end)

    params = %{
      client_id: @client_id,
      redirect_uri: @redirect_uri,
      response_type: "code",
      state: "xyz",
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: "http://localhost:4000/beamlet/mcp"
    }

    %{conn: sign_in(build_conn(), user), params: params}
  end

  defp redirect_query(conn) do
    location = redirected_to(conn)
    assert String.starts_with?(location, @redirect_uri <> "?")
    location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  describe "GET /beamlet/authorize" do
    test "a signed-out person goes to the login and comes back to the same request", %{
      params: params
    } do
      test = self()
      Req.Test.stub(Clients, fn _conn -> send(test, :fetched) && flunk("fetched") end)

      conn = build_conn() |> get("/beamlet/authorize", params)

      assert redirected_to(conn) == "/beamlet/login"

      assert %URI{path: "/beamlet/authorize", query: query} =
               URI.parse(get_session(conn, :return_to))

      assert URI.decode_query(query) == Map.new(params, fn {k, v} -> {to_string(k), v} end)
      refute_received :fetched
    end

    test "renders the consent page", %{conn: conn, params: params} do
      html = conn |> get("/beamlet/authorize", params) |> html_response(200)

      assert html =~ "chat.example wants to connect."
      assert html =~ ~s(id="client-id")
      assert html =~ @client_id
      assert html =~ ~s(action="/beamlet/authorize")
      assert html =~ ~s(name="_csrf_token")
      assert html =~ ~s(type="radio" name="policy" value="default" checked)
      assert html =~ "define, eval"
      assert html =~ ~s(name="decision" value="allow")
      assert html =~ ~s(name="decision" value="deny")
      assert html =~ "Signed in as alice."
      refute html =~ "loopback-warning"

      for {name, value} <- params do
        assert html =~ ~s(type="hidden" name="#{name}" value="#{value}")
      end
    end

    @tag policies: [explorer: [tools: [:eval]]]
    test "lists every declared policy with its tools, default selected", %{
      conn: conn,
      params: params
    } do
      html = conn |> get("/beamlet/authorize", params) |> html_response(200)

      assert html =~ ~s(name="policy" value="default" checked)
      assert html =~ ~s(name="policy" value="explorer")
      refute html =~ ~s(name="policy" value="explorer" checked)
      assert [_, after_explorer] = String.split(html, ~s(value="explorer"), parts: 2)
      assert after_explorer =~ ">eval<"
    end

    @tag policies: [explorer: [tools: [:eval]], restricted: [tools: [:eval]]]
    test "offers a bounded user only their policies, the first selected unless default is among them",
         %{params: params} do
      {:ok, bob} = Users.create(name: "bob", policies: ["restricted", "explorer"])

      html =
        build_conn() |> sign_in(bob) |> get("/beamlet/authorize", params) |> html_response(200)

      assert html =~ ~s(name="policy" value="restricted" checked)
      assert html =~ ~s(name="policy" value="explorer")
      refute html =~ ~s(name="policy" value="explorer" checked)
      refute html =~ ~s(value="default")

      {:ok, bob} = Users.update(bob, policies: ["explorer", "default"])

      html =
        build_conn() |> sign_in(bob) |> get("/beamlet/authorize", params) |> html_response(200)

      assert html =~ ~s(name="policy" value="default" checked)
      refute html =~ ~s(name="policy" value="explorer" checked)
      refute html =~ ~s(value="restricted")
    end

    test "warns when the redirect is loopback", %{conn: conn, params: params} do
      params = %{params | redirect_uri: "http://127.0.0.1:51234/callback"}
      html = conn |> get("/beamlet/authorize", params) |> html_response(200)

      assert html =~ ~s(id="loopback-warning")
      assert html =~ "http://127.0.0.1:51234/callback"
    end

    test "an unknown client is an error page, not a redirect", %{conn: conn, params: params} do
      Req.Test.stub(Clients, fn conn -> conn |> put_status(404) |> Req.Test.json(%{}) end)
      html = conn |> get("/beamlet/authorize", params) |> html_response(400)
      assert html =~ "could not verify the app"
      assert html =~ "client metadata document"

      html =
        conn |> get("/beamlet/authorize", Map.delete(params, :client_id)) |> html_response(400)

      assert html =~ "could not verify the app"
    end

    test "a redirect URI the document does not list is an error page", %{
      conn: conn,
      params: params
    } do
      params = %{params | redirect_uri: "https://evil.example/callback"}
      html = conn |> get("/beamlet/authorize", params) |> html_response(400)
      assert html =~ "does not list"

      html =
        conn |> get("/beamlet/authorize", Map.delete(params, :redirect_uri)) |> html_response(400)

      assert html =~ "does not list"
    end

    test "every other fault redirects to the client with an error, the state and iss", %{
      conn: conn,
      params: params
    } do
      faults = [
        {%{params | response_type: "token"}, "unsupported_response_type"},
        {Map.delete(params, :code_challenge), "invalid_request"},
        {%{params | code_challenge_method: "plain"}, "invalid_request"},
        {Map.delete(params, :code_challenge_method), "invalid_request"},
        {%{params | resource: "http://localhost:4000/other"}, "invalid_target"}
      ]

      for {params, error} <- faults do
        query = conn |> get("/beamlet/authorize", params) |> redirect_query()
        assert %{"error" => ^error, "state" => "xyz", "iss" => @iss} = query
        assert query["error_description"] != nil
      end
    end

    test "state and resource are optional", %{conn: conn, params: params} do
      params = params |> Map.delete(:state) |> Map.delete(:resource)

      assert conn |> get("/beamlet/authorize", params) |> html_response(200) =~
               "chat.example wants to connect."
    end
  end

  describe "POST /beamlet/authorize" do
    test "allow stores a code and sends the browser back with code, state and iss", %{
      conn: conn,
      params: params,
      user: user
    } do
      query =
        conn
        |> post("/beamlet/authorize", Map.merge(params, %{decision: "allow", policy: "default"}))
        |> redirect_query()

      assert %{"code" => code, "state" => "xyz", "iss" => @iss} = query
      refute Map.has_key?(query, "error")

      assert Codes.take(code) ==
               {:ok,
                %{
                  user_id: user.id,
                  policy: "default",
                  client_id: @client_id,
                  redirect_uri: @redirect_uri,
                  code_challenge: @challenge,
                  resource: "http://localhost:4000/beamlet/mcp",
                  scope: nil
                }}
    end

    @tag policies: [explorer: [tools: [:eval]]]
    test "the chosen policy and the requested scope go into the code", %{
      conn: conn,
      params: params
    } do
      params =
        Map.merge(params, %{decision: "allow", policy: "explorer", scope: "offline_access"})

      %{"code" => code} = conn |> post("/beamlet/authorize", params) |> redirect_query()

      assert {:ok, %{policy: "explorer", scope: "offline_access"}} = Codes.take(code)
    end

    test "deny sends the browser back with access_denied", %{conn: conn, params: params} do
      query =
        conn |> post("/beamlet/authorize", Map.put(params, :decision, "deny")) |> redirect_query()

      assert %{"error" => "access_denied", "state" => "xyz", "iss" => @iss} = query
      refute Map.has_key?(query, "code")
    end

    test "a custom-scheme redirect is a page that sends the browser on", %{
      conn: conn,
      params: params
    } do
      params =
        Map.merge(params, %{
          redirect_uri: "chat-app://oauth/callback",
          decision: "allow",
          policy: "default"
        })

      html = conn |> post("/beamlet/authorize", params) |> html_response(200)

      assert html =~ "Sending you back to chat.example"
      assert [location] = Regex.run(~r{content="0;url=([^"]+)"}, html, capture: :all_but_first)
      assert html =~ ~s(href="#{location}")

      assert %URI{scheme: "chat-app", host: "oauth", path: "/callback", query: query} =
               location |> String.replace("&amp;", "&") |> URI.parse()

      assert %{"code" => code, "state" => "xyz", "iss" => @iss} = URI.decode_query(query)
      assert {:ok, %{policy: "default"}} = Codes.take(code)
    end

    test "a redirect URI with a query keeps it", %{conn: conn, params: params} do
      params =
        Map.merge(params, %{redirect_uri: "https://chat.example/cb?app=1", decision: "deny"})

      location = conn |> post("/beamlet/authorize", params) |> redirected_to()
      assert String.starts_with?(location, "https://chat.example/cb?app=1&error=access_denied")
    end

    test "a policy the beamlet does not declare, or no decision, is an error page", %{
      conn: conn,
      params: params
    } do
      params = Map.merge(params, %{decision: "allow", policy: "root"})

      assert conn |> post("/beamlet/authorize", params) |> html_response(400) =~
               "not one this beamlet"

      params = Map.put(params, :decision, "maybe")
      assert conn |> post("/beamlet/authorize", params) |> html_response(400) =~ "incomplete"
    end

    @tag policies: [explorer: [tools: [:eval]]]
    test "a policy outside the user's list is an error page", %{params: params} do
      {:ok, bob} = Users.create(name: "bob", policies: ["explorer"])
      params = Map.merge(params, %{decision: "allow", policy: "default"})

      assert build_conn()
             |> sign_in(bob)
             |> post("/beamlet/authorize", params)
             |> html_response(400) =~
               "not one this beamlet lets you use"
    end

    test "the form is validated again, so a tampered redirect URI is an error page", %{
      conn: conn,
      params: params
    } do
      params =
        Map.merge(params, %{
          redirect_uri: "https://evil.example/cb",
          decision: "allow",
          policy: "default"
        })

      assert conn |> post("/beamlet/authorize", params) |> html_response(400) =~ "does not list"
    end

    test "a signed-out post goes to the login", %{params: params} do
      conn = build_conn() |> post("/beamlet/authorize", Map.put(params, :decision, "allow"))
      assert redirected_to(conn) == "/beamlet/login"
    end
  end
end
