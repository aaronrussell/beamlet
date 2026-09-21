defmodule Beamlet.Web.SessionControllerTest do
  use Beamlet.Case

  import Phoenix.ConnTest
  import Plug.Conn

  alias Beamlet.Users

  setup %{user: user} do
    {:ok, user} = Users.update_password(user, "correct horse")
    %{conn: build_conn(), user: user}
  end

  describe "GET /beamlet/login" do
    test "renders the form", %{conn: conn} do
      html = conn |> get("/beamlet/login") |> html_response(200)

      assert html =~ "Sign in to your beamlet"
      assert html =~ ~s(action="/beamlet/login")
      assert html =~ ~s(name="user[name]")
      assert html =~ ~s(name="user[password]")
      assert html =~ ~s(name="_csrf_token")
    end

    test "sends a signed-in user home", %{conn: conn, user: user} do
      assert conn |> sign_in(user) |> get("/beamlet/login") |> redirected_to() == "/beamlet"
    end
  end

  describe "POST /beamlet/login" do
    test "signs in with the right name and password", %{conn: conn, user: user} do
      conn = post(conn, "/beamlet/login", user: %{name: "alice", password: "correct horse"})

      assert redirected_to(conn) == "/beamlet"
      assert get_session(conn, :user_id) == user.id
    end

    test "returns to the path require_login stored, once", %{conn: conn} do
      conn =
        conn
        |> init_test_session(return_to: "/beamlet?tab=files")
        |> post("/beamlet/login", user: %{name: "alice", password: "correct horse"})

      assert redirected_to(conn) == "/beamlet?tab=files"
      assert get_session(conn, :return_to) == nil
    end

    test "a wrong password re-renders the form and signs nobody in", %{conn: conn} do
      conn = post(conn, "/beamlet/login", user: %{name: "alice", password: "wrong"})

      assert html_response(conn, 200) =~ "Wrong name or password."
      assert get_session(conn, :user_id) == nil
    end

    test "an unknown name and a user with no password fail the same way", %{conn: conn} do
      {:ok, _bob} = Users.create(name: "bob")

      for name <- ["carol", "bob"] do
        conn = post(conn, "/beamlet/login", user: %{name: name, password: "correct horse"})
        assert html_response(conn, 200) =~ "Wrong name or password."
        assert get_session(conn, :user_id) == nil
      end
    end

    test "a body without the form's fields fails the same way", %{conn: conn} do
      conn = post(conn, "/beamlet/login", %{})
      assert html_response(conn, 200) =~ "Wrong name or password."
      assert get_session(conn, :user_id) == nil
    end
  end

  describe "POST /beamlet/logout" do
    test "clears the session and returns to the login page", %{conn: conn, user: user} do
      conn = conn |> sign_in(user) |> post("/beamlet/logout")

      assert redirected_to(conn) == "/beamlet/login"
      assert get_session(conn, :user_id) == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed out."
    end
  end
end
