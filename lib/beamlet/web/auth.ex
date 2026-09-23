defmodule Beamlet.Web.Auth do
  @moduledoc """
  The web sign-in: who the browser is, kept in the session.

  A signed-in user is a web identity, a `Beamlet.User` on a request
  with no token and no policy, since a browser authors no code. The
  session holds the user's id and nothing else; every request loads
  the user again, so a renamed user stays signed in and a deleted one
  is signed out.

  Two plugs for `Beamlet.Router`'s browser pipeline and any host route
  that wants the same: `fetch_current_user/2` assigns `:current_user`,
  nil when nobody is signed in, and `require_auth/2` sends a signed-out
  request to the login page, remembering where a GET was headed so
  the sign-in returns there. `on_mount/4` is the LiveView form of
  `require_auth`, for a `live_session`:

      live_session :beamlet, on_mount: [{Beamlet.Web.Auth, :require_auth}] do
        live "/", HomeLive
      end

  `on_mount(:fetch_current_user, ...)` assigns the user without a
  redirect, for a page that renders either way, such as the sign-in.

  `log_in/2` and `log_out/1` are what the session controller calls;
  both renew the session so a sign-in never keeps a cookie that was
  handed out before it.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [current_path: 1, put_flash: 3, redirect: 2]

  alias Beamlet.User
  alias Beamlet.Users

  @login_path "/beamlet/login"
  @flash "Sign in to continue."

  @doc "Assigns `:current_user` from the session: the user, or nil when nobody is signed in."
  @spec fetch_current_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    assign(conn, :current_user, user_from(get_session(conn, :user_id)))
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

  @doc "Signs the user in: renews the session and stores the user's id."
  @spec log_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def log_in(conn, %User{id: id}) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, id)
  end

  @doc "Signs out: clears the session and renews it."
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
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
    {:cont, Phoenix.Component.assign(socket, :current_user, user_from(session["user_id"]))}
  end

  def on_mount(:require_auth, _params, session, socket) do
    case user_from(session["user_id"]) do
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

  defp user_from(nil), do: nil

  defp user_from(id) do
    case Users.find(id) do
      {:ok, user} -> user
      {:error, :not_found} -> nil
    end
  end

  defp store_return_path(%Plug.Conn{method: "GET"} = conn) do
    put_session(conn, :return_to, current_path(conn))
  end

  defp store_return_path(conn), do: conn
end
