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

  test "a user deleted since signing in is signed out", %{conn: conn, user: user} do
    conn = sign_in(conn, user)
    {:ok, _user} = Users.delete(user)

    assert {:error, {:redirect, %{to: "/beamlet/login"}}} = live(conn, "/beamlet")
  end
end
