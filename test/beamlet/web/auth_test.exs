defmodule Beamlet.Web.AuthTest do
  use Beamlet.Case

  import Plug.Conn
  import Plug.Test

  alias Beamlet.User
  alias Beamlet.Users
  alias Beamlet.Web.Auth

  defp session_conn(method, path, session) do
    method
    |> conn(path)
    |> init_test_session(session)
    |> Phoenix.Controller.fetch_flash([])
  end

  describe "fetch_current_user/2" do
    test "assigns the user the session names", %{user: user} do
      conn = :get |> session_conn("/x", user_id: user.id) |> Auth.fetch_current_user([])
      assert %User{name: "alice"} = conn.assigns.current_user
    end

    test "assigns nil with no session, and once the user is gone", %{user: user} do
      conn = :get |> session_conn("/x", %{}) |> Auth.fetch_current_user([])
      assert conn.assigns.current_user == nil

      {:ok, _user} = Users.delete(user)
      conn = :get |> session_conn("/x", user_id: user.id) |> Auth.fetch_current_user([])
      assert conn.assigns.current_user == nil
    end
  end

  describe "require_login/2" do
    test "passes a signed-in request through", %{user: user} do
      conn =
        :get |> session_conn("/x", %{}) |> assign(:current_user, user) |> Auth.require_login([])

      refute conn.halted
    end

    test "halts a signed-out GET with a redirect, remembering the path" do
      conn =
        :get
        |> session_conn("/beamlet?tab=files", %{})
        |> Auth.fetch_current_user([])
        |> Auth.require_login([])

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/beamlet/login"]
      assert get_session(conn, :return_to) == "/beamlet?tab=files"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Sign in to continue."
    end

    test "remembers nothing for a POST" do
      conn =
        :post
        |> session_conn("/beamlet/things", %{})
        |> Auth.fetch_current_user([])
        |> Auth.require_login([])

      assert conn.halted
      assert get_resp_header(conn, "location") == ["/beamlet/login"]
      assert get_session(conn, :return_to) == nil
    end
  end

  describe "log_in/2 and log_out/1" do
    test "put the user's id in the session and take it out again", %{user: user} do
      conn = :get |> session_conn("/x", %{}) |> Auth.log_in(user)
      assert get_session(conn, :user_id) == user.id

      conn = Auth.log_out(conn)
      assert get_session(conn, :user_id) == nil
    end
  end

  describe "on_mount/4" do
    test "continues with the user assigned", %{user: user} do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert {:cont, socket} = Auth.on_mount(:require_login, %{}, %{"user_id" => user.id}, socket)
      assert %User{name: "alice"} = socket.assigns.current_user
    end

    test "halts with a redirect to the login page when nobody is signed in", %{user: user} do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert {:halt, halted} = Auth.on_mount(:require_login, %{}, %{}, socket)
      assert {:redirect, %{to: "/beamlet/login"}} = halted.redirected

      {:ok, _user} = Users.delete(user)

      assert {:halt, halted} =
               Auth.on_mount(:require_login, %{}, %{"user_id" => user.id}, socket)

      assert {:redirect, %{to: "/beamlet/login"}} = halted.redirected
    end
  end
end
