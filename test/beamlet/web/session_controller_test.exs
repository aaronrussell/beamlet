defmodule Beamlet.Web.SessionControllerTest do
  use Beamlet.Case, shared: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias Beamlet.Owner
  alias Beamlet.Repo

  setup do
    %{conn: build_conn()}
  end

  describe "GET /beamlet/login" do
    test "renders the form, posting to this controller", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/beamlet/login")

      assert has_element?(view, ~s(form#login-form[action="/beamlet/login"][method="post"]))
      assert has_element?(view, ~s(#login-form input[name="user[email]"][type="email"]))
      assert has_element?(view, ~s(#login-form input[name="user[password]"]))
      assert has_element?(view, ~s(#login-form input[name="_csrf_token"]))
    end

    test "sends a signed-in owner home", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/beamlet"}}} =
               conn |> sign_in() |> live("/beamlet/login")
    end
  end

  describe "POST /beamlet/login" do
    test "signs in with the right email and password", %{
      conn: conn,
      user: user,
      password: password
    } do
      conn = post(conn, "/beamlet/login", user: %{email: "Owner@Example.com", password: password})

      assert redirected_to(conn) == "/beamlet"
      assert {:ok, ^user} = Owner.authenticate_session(get_session(conn, :session_secret))

      cookie = conn.resp_cookies["_beamlet_app_key"]
      assert cookie.path == "/beamlet"
      assert cookie.http_only
    end

    test "returns to the path require_auth stored, once", %{conn: conn, password: password} do
      conn =
        conn
        |> init_test_session(return_to: "/beamlet?tab=files")
        |> post("/beamlet/login", user: %{email: "owner@example.com", password: password})

      assert redirected_to(conn) == "/beamlet?tab=files"
      assert get_session(conn, :return_to) == nil
    end

    test "a wrong password goes back to the form with a flash and signs nobody in", %{
      conn: conn
    } do
      conn = post(conn, "/beamlet/login", user: %{email: "owner@example.com", password: "wrong"})

      assert redirected_to(conn) == "/beamlet/login"
      assert get_session(conn, :session_secret) == nil

      {:ok, view, _html} = live(conn, "/beamlet/login")
      assert has_element?(view, "#flash-error", "Wrong email or password.")
    end

    test "an unknown email, and a beamlet with no owner yet, fail the same way", %{
      conn: conn,
      user: user,
      password: password
    } do
      for email <- ["other@example.com", "owner@example.com"] do
        if email == "owner@example.com", do: Repo.delete!(user)

        conn = post(conn, "/beamlet/login", user: %{email: email, password: password})
        assert redirected_to(conn) == "/beamlet/login"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Wrong email or password."
        assert get_session(conn, :session_secret) == nil
      end
    end

    test "a body without the form's fields fails the same way", %{conn: conn} do
      conn = post(conn, "/beamlet/login", %{})
      assert redirected_to(conn) == "/beamlet/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Wrong email or password."
      assert get_session(conn, :session_secret) == nil
    end
  end

  describe "POST /beamlet/logout" do
    test "ends the session and returns to the login page", %{conn: conn} do
      conn = sign_in(conn)
      secret = get_session(conn, :session_secret)
      conn = post(conn, "/beamlet/logout")

      assert redirected_to(conn) == "/beamlet/login"
      assert get_session(conn, :session_secret) == nil
      assert Owner.authenticate_session(secret) == {:error, :unknown_session}
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed out."
    end
  end
end
