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

  describe "session_options/0" do
    test "name a cookie of the app's own, scoped to /beamlet and hidden from scripts" do
      options = Auth.session_options()

      assert options[:key] == "_beamlet_app_key"
      assert options[:path] == "/beamlet"
      assert options[:http_only] == true
    end
  end

  describe "fetch_current_user/2" do
    test "assigns the user whose session the secret names", %{user: user} do
      {:ok, session} = Users.create_session(user)

      conn =
        :get
        |> session_conn("/x", session_secret: session.secret)
        |> Auth.fetch_current_user([])

      assert %User{name: "alice"} = conn.assigns.current_user
    end

    test "assigns nil with no session, and once the session or the user is gone", %{user: user} do
      conn = :get |> session_conn("/x", %{}) |> Auth.fetch_current_user([])
      assert conn.assigns.current_user == nil

      {:ok, session} = Users.create_session(user)
      {:ok, _session} = Users.delete_session(session)

      conn =
        :get |> session_conn("/x", session_secret: session.secret) |> Auth.fetch_current_user([])

      assert conn.assigns.current_user == nil

      {:ok, session} = Users.create_session(user)
      {:ok, _user} = Users.delete(user)

      conn =
        :get |> session_conn("/x", session_secret: session.secret) |> Auth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end

    test "a session naming a user id signs nobody in", %{user: user} do
      conn = :get |> session_conn("/x", user_id: user.id) |> Auth.fetch_current_user([])
      assert conn.assigns.current_user == nil
    end
  end

  describe "require_auth/2" do
    test "passes a signed-in request through", %{user: user} do
      conn =
        :get |> session_conn("/x", %{}) |> assign(:current_user, user) |> Auth.require_auth([])

      refute conn.halted
    end

    test "halts a signed-out GET with a redirect, remembering the path" do
      conn =
        :get
        |> session_conn("/beamlet?tab=files", %{})
        |> Auth.fetch_current_user([])
        |> Auth.require_auth([])

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
        |> Auth.require_auth([])

      assert conn.halted
      assert get_resp_header(conn, "location") == ["/beamlet/login"]
      assert get_session(conn, :return_to) == nil
    end
  end

  describe "log_in/2 and log_out/1" do
    test "create a session and keep its secret, then delete it and forget it", %{user: user} do
      conn = :get |> session_conn("/x", %{}) |> Auth.log_in(user)
      secret = get_session(conn, :session_secret)
      assert {:ok, %{user: %User{name: "alice"}}} = Users.authenticate_session(secret)

      conn = Auth.log_out(conn)
      assert get_session(conn, :session_secret) == nil
      assert Users.authenticate_session(secret) == {:error, :unknown_session}
    end
  end

  describe "on_mount/4" do
    test "continues with the user assigned", %{user: user} do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
      {:ok, session} = Users.create_session(user)

      assert {:cont, socket} =
               Auth.on_mount(:require_auth, %{}, %{"session_secret" => session.secret}, socket)

      assert %User{name: "alice"} = socket.assigns.current_user
    end

    test "halts with a redirect to the login page when nobody is signed in", %{user: user} do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      assert {:halt, halted} = Auth.on_mount(:require_auth, %{}, %{}, socket)
      assert {:redirect, %{to: "/beamlet/login"}} = halted.redirected

      {:ok, session} = Users.create_session(user)
      {:ok, _user} = Users.delete(user)

      assert {:halt, halted} =
               Auth.on_mount(:require_auth, %{}, %{"session_secret" => session.secret}, socket)

      assert {:redirect, %{to: "/beamlet/login"}} = halted.redirected
    end
  end
end
