defmodule Beamlet.Web.Auth do
  @moduledoc """
  The web sign-in: who the browser is, kept in the app's own session.

  A signed-in user is a web identity, a `Beamlet.User` on a request
  with no token and no policy, since a browser authors no code.

  The app keeps a cookie of its own, apart from the endpoint's session
  that agent pages use: `session_options/0`, scoped to `/beamlet` and
  unreadable by page scripts. `Beamlet.Router` plugs it into its
  browser pipeline, and the app's LiveView socket at
  `/beamlet/app/live` decodes it. The session holds one value, the
  secret of a `Beamlet.Session` row in the system database, and every
  request turns it back into the user through
  `Beamlet.Users.authenticate_session/1`. Nothing agent code can
  write signs anyone in: an agent page's session is a different
  cookie, and a cookie forged with the endpoint's `secret_key_base`
  still needs a secret that matches a row. A renamed user stays
  signed in; a deleted one, or one whose password was reset, is
  signed out.

  Two plugs for `Beamlet.Router`'s browser pipeline:
  `fetch_current_user/2` assigns `:current_user`, nil when nobody is
  signed in, and `require_auth/2` sends a signed-out request to the
  login page, remembering where a GET was headed so the sign-in
  returns there. `on_mount/4` is the LiveView form of `require_auth`,
  for a `live_session`:

      live_session :beamlet, on_mount: [{Beamlet.Web.Auth, :require_auth}] do
        live "/", HomeLive
      end

  `on_mount(:fetch_current_user, ...)` assigns the user without a
  redirect, for a page that renders either way, such as the sign-in.

  `log_in/2` and `log_out/1` are what the session controller calls:
  the first creates a session, the second deletes it, and both renew
  the cookie so a sign-in never keeps one handed out before it.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [current_path: 1, put_flash: 3, redirect: 2]

  alias Beamlet.Session
  alias Beamlet.User
  alias Beamlet.Users

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
  The `Plug.Session` options for the app's cookie.

  `Beamlet.Router` plugs them into its browser pipeline, and a host's
  endpoint names them for the app's LiveView socket:

      socket "/beamlet/app/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [session: {Beamlet.Web.Auth, :session_options, []}]]
  """
  @spec session_options() :: keyword()
  def session_options, do: @session_options

  @doc "Assigns `:current_user` from the session: the user, or nil when nobody is signed in."
  @spec fetch_current_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    assign(conn, :current_user, user_from(get_session(conn, :session_secret)))
  end

  @doc """
  Halts a signed-out request with a redirect to the login page,
  storing the path of a GET as where to return after.
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

  @doc "Signs the user in: creates a session, renews the cookie and stores the session's secret."
  @spec log_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def log_in(conn, %User{} = user) do
    {:ok, %Session{secret: secret}} = Users.create_session(user)

    conn
    |> configure_session(renew: true)
    |> put_session(:session_secret, secret)
  end

  @doc "Signs out: deletes the session, clears the cookie and renews it."
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    with {:ok, session} <- Users.authenticate_session(get_session(conn, :session_secret)) do
      Users.delete_session(session)
    end

    conn
    |> clear_session()
    |> configure_session(renew: true)
  end

  @doc """
  The hooks for a `live_session`: `:require_auth` assigns
  `:current_user` or halts with a redirect to the login page;
  `:fetch_current_user` assigns it, nil when nobody is signed in.
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
    case Users.authenticate_session(secret) do
      {:ok, %Session{user: user}} -> user
      {:error, :unknown_session} -> nil
    end
  end

  defp store_return_path(%Plug.Conn{method: "GET"} = conn) do
    put_session(conn, :return_to, current_path(conn))
  end

  defp store_return_path(conn), do: conn
end
