defmodule Beamlet.Web.SessionController do
  @moduledoc """
  Sign in and sign out, the two actions that write the session:
  `POST /beamlet/login` and `POST /beamlet/logout`.

  The form itself is `Beamlet.Web.SessionLive`; it posts here because
  a session cookie is written on an HTTP response. The name and
  password are checked through `Beamlet.Users.authenticate_password/2`;
  a sign-in lands where `Beamlet.Web.Auth.require_auth/2` stored, or
  on the home page, and a failure goes back to the form with a flash.
  A user with no password cannot sign in until the operator sets one
  with `beamlet users.update --password`.
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Beamlet.Users
  alias Beamlet.Web.Auth

  @home_path "/beamlet"
  @login_path "/beamlet/login"

  @doc "Signs in from the form's name and password, or sends the form back with a flash."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"user" => %{"name" => name, "password" => password}}) do
    case Users.authenticate_password(name, password) do
      {:ok, user} ->
        {return_to, conn} = pop_return_path(conn)

        conn
        |> Auth.log_in(user)
        |> redirect(to: return_to || @home_path)

      {:error, :invalid_credentials} ->
        refuse(conn)
    end
  end

  def create(conn, _params), do: refuse(conn)

  @doc "Signs out and returns to the sign-in page."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> Auth.log_out()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: @login_path)
  end

  defp refuse(conn) do
    conn
    |> put_flash(:error, "Wrong name or password.")
    |> redirect(to: @login_path)
  end

  defp pop_return_path(conn) do
    {get_session(conn, :return_to), delete_session(conn, :return_to)}
  end
end
