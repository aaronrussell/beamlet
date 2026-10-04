defmodule Beamlet.Web.Auth do
  @moduledoc """
  The owner's sign-in to the beamlet's own pages.

  The sign-in is kept in a cookie of its own, scoped to `/beamlet`,
  apart from your endpoint's session.

  The one part you use is `session_options/0`, for the socket the
  beamlet's own pages connect to:

      socket "/beamlet/app/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [session: {Beamlet.Web.Auth, :session_options, []}]]

  `Beamlet.Router` and the beamlet's pages use the rest.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [current_path: 1, put_flash: 3, redirect: 2]

  alias Beamlet.Config
  alias Beamlet.Owner
  alias Beamlet.Session
  alias Beamlet.User

  @login_path "/beamlet/login"
  @flash "Sign in to continue."

  @session_options [
    store: :cookie,
    key: "_beamlet_app_key",
    signing_salt: "beamlet-app",
    path: "/beamlet",
    http_only: true,
    same_site: "Lax"
  ]

  @doc """
  The `Plug.Session` options for the sign-in's cookie.

  `Beamlet.Router` plugs them in for the beamlet's own pages, and your
  endpoint names them for the socket at `/beamlet/app/live`.
  """
  @spec session_options() :: keyword()
  def session_options, do: @session_options

  @doc """
  Assigns `:current_user` from the session.

  It is `nil` when nobody is signed in.
  """
  @spec fetch_current_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    assign(conn, :current_user, user_from(get_session(conn, :session_secret)))
  end

  @doc """
  Halts a signed-out request with a redirect to the login page.

  The path of a GET is stored, so the sign-in returns there.
  """
  @spec require_auth(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_auth(%Plug.Conn{assigns: %{current_user: %User{}}} = conn, _opts), do: conn

  def require_auth(conn, _opts) do
    conn
    |> store_return_path()
    |> put_flash(:error, @flash)
    |> redirect(to: @login_path)
    |> halt()
  end

  @doc """
  Signs the owner in.

  It creates a session, renews the cookie, and stores the session's
  secret and the id the app's LiveView sockets on it take.
  """
  @spec log_in(Plug.Conn.t(), %User{}) :: Plug.Conn.t()
  def log_in(conn, %User{}) do
    {:ok, %Session{id: id, secret: secret}} = Owner.create_session()

    conn
    |> configure_session(renew: true)
    |> put_session(:session_secret, secret)
    |> put_session(:live_socket_id, "beamlet_app_session:#{id}")
  end

  @doc """
  Signs the owner out.

  It disconnects the app's LiveViews on the session, deletes the
  session, and clears and renews the cookie.
  """
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      Config.web()[:endpoint].broadcast(live_socket_id, "disconnect", %{})
    end

    Owner.delete_session(get_session(conn, :session_secret))

    conn
    |> clear_session()
    |> configure_session(renew: true)
  end

  @doc """
  The hooks for a `live_session`.

  `:require_auth` assigns `:current_user`, or halts with a redirect
  to the login page. `:fetch_current_user` assigns it, `nil` when
  nobody is signed in.
  """
  @spec on_mount(:require_auth | :fetch_current_user, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:fetch_current_user, _params, session, socket) do
    {:cont, Phoenix.Component.assign(socket, :current_user, user_from(session["session_secret"]))}
  end

  def on_mount(:require_auth, _params, session, socket) do
    case user_from(session["session_secret"]) do
      %User{} = user ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}

      nil ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, @flash)
          |> Phoenix.LiveView.redirect(to: @login_path)

        {:halt, socket}
    end
  end

  defp user_from(secret) do
    case Owner.authenticate_session(secret) do
      {:ok, user} -> user
      {:error, :unknown_session} -> nil
    end
  end

  defp store_return_path(%Plug.Conn{method: "GET"} = conn) do
    put_session(conn, :return_to, current_path(conn))
  end

  defp store_return_path(conn), do: conn
end
