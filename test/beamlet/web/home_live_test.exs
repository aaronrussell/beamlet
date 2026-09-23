defmodule Beamlet.Web.HomeLiveTest do
  use Beamlet.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Beamlet.Users

  setup do
    %{conn: build_conn()}
  end

  test "signed out is sent to the login page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/beamlet/login"}}} = live(conn, "/beamlet")
  end

  test "signed in shows the user and a sign-out form", %{conn: conn, user: user} do
    {:ok, view, html} = conn |> sign_in(user) |> live("/beamlet")

    assert html =~ "Signed in as alice."
    assert has_element?(view, ~s(form#logout-form[action="/beamlet/logout"][method="post"]))
    assert has_element?(view, "form#logout-form input[name=_csrf_token]")
  end

  test "shows the MCP URL and how each kind of client connects", %{conn: conn, user: user} do
    conn = sign_in(conn, user)
    {:ok, view, html} = live(conn, "/beamlet")

    assert has_element?(view, "#mcp-url", "http://localhost:4000/beamlet/mcp")
    assert has_element?(view, "h2", "ChatGPT")
    assert html =~ "Browse plugins"

    for {client, heading, snippet} <- [
          {"claude", "Claude", "Add custom connector"},
          {"claude-code", "Claude Code",
           "claude mcp add --transport http beamlet http://localhost:4000/beamlet/mcp"},
          {"cursor", "Cursor", "Bearer ${env:BEAMLET_TOKEN}"},
          {"code", "From code", "mcp-client-2025-11-20"},
          {"other", "Other apps", "send it as a header"}
        ] do
      {:ok, view, html} = live(conn, "/beamlet?client=#{client}")

      assert has_element?(view, "h2", heading), "no heading #{heading}"
      assert html =~ snippet, "#{client} lacks #{snippet}"
    end

    {:ok, view, html} = live(conn, "/beamlet?client=code")
    assert has_element?(view, "pre", "beamlet tokens.create NAME --user alice")
    assert html =~ ~s(server_label: &quot;beamlet&quot;)

    {:ok, view, _html} = live(conn, "/beamlet?client=nonsense")
    assert has_element?(view, "h2", "ChatGPT")
  end

  test "renders in the beamlet's own layout, with the built stylesheet", %{conn: conn, user: user} do
    html = conn |> sign_in(user) |> get("/beamlet") |> html_response(200)

    assert html =~ ~s(<link rel="stylesheet" href="/beamlet/assets/beamlet.css")
    refute html =~ "cdn.jsdelivr.net"
  end

  test "a user deleted since signing in is signed out", %{conn: conn, user: user} do
    conn = sign_in(conn, user)
    {:ok, _user} = Users.delete(user)

    assert {:error, {:redirect, %{to: "/beamlet/login"}}} = live(conn, "/beamlet")
  end
end
