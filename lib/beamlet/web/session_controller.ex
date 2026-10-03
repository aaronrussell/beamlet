defmodule Beamlet.Web.SessionController do
  @moduledoc false

  # Sign in and sign out, the two actions that write the session:
  # `POST /beamlet/login` and `POST /beamlet/logout`.
  #
  # The form itself is `Beamlet.Web.SessionLive`; it posts here because
  # a session cookie is written on an HTTP response. The email and
  # password are checked through `Beamlet.Owner.authenticate/2`; a
  # sign-in lands where `Beamlet.Web.Auth.require_auth/2` stored, or on
  # the home page, and a failure goes back to the form with a flash.
  # Nobody can sign in until `beamlet setup` has created the owner.

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Beamlet.Owner
  alias Beamlet.Web.Auth

  @home_path "/beamlet"
  @login_path "/beamlet/login"

  @doc "Signs in from the form's email and password, or sends the form back with a flash."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Owner.authenticate(email, password) do
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
    |> put_flash(:error, "Wrong email or password.")
    |> redirect(to: @login_path)
  end

  defp pop_return_path(conn) do
    {get_session(conn, :return_to), delete_session(conn, :return_to)}
  end
end
