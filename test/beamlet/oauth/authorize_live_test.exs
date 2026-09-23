defmodule Beamlet.OAuth.AuthorizeLiveTest do
  use Beamlet.Case

  @moduletag :capture_log

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
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

  defp path(params), do: "/beamlet/authorize?" <> URI.encode_query(params)

  defp query(location, prefix \\ @redirect_uri) do
    assert String.starts_with?(location, prefix <> "?")
    location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  defp redirect_query(conn), do: conn |> redirected_to() |> query()

  defp decide(view, decision, policy) do
    view
    |> element("#consent-form")
    |> render_submit(%{"decision" => decision, "policy" => policy})
  end

  describe "arriving at /beamlet/authorize" do
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
      {:ok, view, html} = live(conn, path(params))

      assert html =~ "chat.example wants to connect."
      assert has_element?(view, "#client-id", @client_id)

      assert has_element?(
               view,
               ~s(#consent-form input[type=radio][name=policy][value=default][checked])
             )

      assert html =~ "define, eval"
      assert has_element?(view, ~s(#consent-form button[name=decision][value=allow]))
      assert has_element?(view, ~s(#consent-form button[name=decision][value=deny]))
      assert has_element?(view, "#signed-in", "alice")
      refute has_element?(view, "#loopback-warning")
    end

    @tag policies: [explorer: [tools: [:eval]]]
    test "lists every declared policy with its tools, default selected", %{
      conn: conn,
      params: params
    } do
      {:ok, view, _html} = live(conn, path(params))

      assert has_element?(view, ~s(input[name=policy][value=default][checked]))
      assert has_element?(view, ~s(input[name=policy][value=explorer]))
      refute has_element?(view, ~s(input[name=policy][value=explorer][checked]))
      assert [_, after_explorer] = String.split(render(view), ~s(value="explorer"), parts: 2)
      assert after_explorer =~ ">eval<"
    end

    @tag policies: [explorer: [tools: [:eval]], restricted: [tools: [:eval]]]
    test "offers a bounded user only their policies, the first selected unless default is among them",
         %{params: params} do
      {:ok, bob} = Users.create(name: "bob", policies: ["restricted", "explorer"])
      {:ok, view, _html} = build_conn() |> sign_in(bob) |> live(path(params))

      assert has_element?(view, ~s(input[name=policy][value=restricted][checked]))
      assert has_element?(view, ~s(input[name=policy][value=explorer]))
      refute has_element?(view, ~s(input[name=policy][value=explorer][checked]))
      refute has_element?(view, ~s(input[name=policy][value=default]))

      {:ok, bob} = Users.update(bob, policies: ["explorer", "default"])
      {:ok, view, _html} = build_conn() |> sign_in(bob) |> live(path(params))

      assert has_element?(view, ~s(input[name=policy][value=default][checked]))
      refute has_element?(view, ~s(input[name=policy][value=explorer][checked]))
      refute has_element?(view, ~s(input[name=policy][value=restricted]))
    end

    test "warns when the redirect is loopback", %{conn: conn, params: params} do
      params = %{params | redirect_uri: "http://127.0.0.1:51234/callback"}
      {:ok, view, _html} = live(conn, path(params))

      assert has_element?(view, "#loopback-warning", "http://127.0.0.1:51234/callback")
    end

    test "an unknown client is an error page, not a redirect", %{conn: conn, params: params} do
      Req.Test.stub(Clients, fn conn -> conn |> put_status(404) |> Req.Test.json(%{}) end)
      {:ok, view, _html} = live(conn, path(params))
      assert has_element?(view, "#error-reason", "client metadata document")

      {:ok, view, _html} = live(conn, path(Map.delete(params, :client_id)))
      assert has_element?(view, "#error-reason", "client metadata document")
    end

    test "a redirect URI the document does not list is an error page", %{
      conn: conn,
      params: params
    } do
      {:ok, view, _html} =
        live(conn, path(%{params | redirect_uri: "https://evil.example/callback"}))

      assert has_element?(view, "#error-reason", "does not list")

      {:ok, view, _html} = live(conn, path(Map.delete(params, :redirect_uri)))
      assert has_element?(view, "#error-reason", "does not list")
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
      {:ok, view, _html} = live(conn, path(params))
      assert has_element?(view, "#consent-form")
    end
  end

  describe "deciding" do
    test "allow stores a code and sends the browser back with code, state and iss", %{
      conn: conn,
      params: params,
      user: user
    } do
      {:ok, view, _html} = live(conn, path(params))

      assert {:error, {:redirect, %{to: location}}} = decide(view, "allow", "default")
      query = query(location)

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
      {:ok, view, _html} = live(conn, path(Map.put(params, :scope, "offline_access")))

      assert {:error, {:redirect, %{to: location}}} = decide(view, "allow", "explorer")
      %{"code" => code} = query(location)

      assert {:ok, %{policy: "explorer", scope: "offline_access"}} = Codes.take(code)
    end

    test "deny sends the browser back with access_denied", %{conn: conn, params: params} do
      {:ok, view, _html} = live(conn, path(params))

      assert {:error, {:redirect, %{to: location}}} = decide(view, "deny", "default")
      query = query(location)

      assert %{"error" => "access_denied", "state" => "xyz", "iss" => @iss} = query
      refute Map.has_key?(query, "code")
    end

    test "a custom-scheme redirect is a page that sends the browser on", %{
      conn: conn,
      params: params
    } do
      {:ok, view, _html} = live(conn, path(%{params | redirect_uri: "chat-app://oauth/callback"}))

      html = decide(view, "allow", "default")

      assert html =~ "Sending you back to chat.example"
      assert [location] = Regex.run(~r{content="0;url=([^"]+)"}, html, capture: :all_but_first)
      assert html =~ ~s(href="#{location}")

      assert %URI{scheme: "chat-app", host: "oauth", path: "/callback", query: query} =
               location |> String.replace("&amp;", "&") |> URI.parse()

      assert %{"code" => code, "state" => "xyz", "iss" => @iss} = URI.decode_query(query)
      assert {:ok, %{policy: "default"}} = Codes.take(code)
    end

    test "a redirect URI with a query keeps it", %{conn: conn, params: params} do
      {:ok, view, _html} =
        live(conn, path(%{params | redirect_uri: "https://chat.example/cb?app=1"}))

      assert {:error, {:redirect, %{to: location}}} = decide(view, "deny", "default")
      assert String.starts_with?(location, "https://chat.example/cb?app=1&error=access_denied")
    end

    test "a policy the beamlet does not declare, or no decision, is an error page", %{
      conn: conn,
      params: params
    } do
      {:ok, view, _html} = live(conn, path(params))
      assert decide(view, "allow", "root") =~ "not one this beamlet"

      {:ok, view, _html} = live(conn, path(params))
      assert decide(view, "maybe", "default") =~ "incomplete"
    end

    @tag policies: [explorer: [tools: [:eval]]]
    test "a policy outside the user's list is an error page", %{params: params} do
      {:ok, bob} = Users.create(name: "bob", policies: ["explorer"])
      {:ok, view, _html} = build_conn() |> sign_in(bob) |> live(path(params))

      assert decide(view, "allow", "default") =~ "not one this beamlet lets you use"
    end

    test "a decision after an error page changes nothing", %{conn: conn, params: params} do
      {:ok, view, _html} = live(conn, path(%{params | redirect_uri: "https://evil.example/cb"}))

      assert render_submit(view, "decide", %{"decision" => "allow", "policy" => "default"}) =~
               "does not list"
    end
  end
end
