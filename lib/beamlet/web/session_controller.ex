defmodule Beamlet.Web.SessionController do
  @moduledoc """
  Sign in and sign out, at `/beamlet/login` and `/beamlet/logout`.

  The form takes a user's name and password and checks them through
  `Beamlet.Users.authenticate_password/2`; a sign-in lands where
  `Beamlet.Web.Auth.require_login/2` stored, or on the home page. A
  user with no password cannot sign in until the operator sets one
  with `beamlet users.update --password`.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Beamlet.User
  alias Beamlet.Users
  alias Beamlet.Web.Auth

  @home_path "/beamlet"
  @login_path "/beamlet/login"

  @doc "Renders the sign-in form, or sends a signed-in user home."
  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(%Plug.Conn{assigns: %{current_user: %User{}}} = conn, _params) do
    redirect(conn, to: @home_path)
  end

  def new(conn, _params), do: render_form(conn)

  @doc "Signs in from the form's name and password, or re-renders it."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"user" => %{"name" => name, "password" => password}}) do
    case Users.authenticate_password(name, password) do
      {:ok, user} ->
        {return_to, conn} = pop_return_path(conn)

        conn
        |> Auth.log_in(user)
        |> redirect(to: return_to || @home_path)

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Wrong name or password.")
        |> render_form()
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Wrong name or password.")
    |> render_form()
  end

  @doc "Signs out and returns to the sign-in page."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> Auth.log_out()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: @login_path)
  end

  defp render_form(conn) do
    conn
    |> assign(:page_title, "Sign in")
    |> render(:new, form: Phoenix.Component.to_form(%{}, as: :user))
  end

  defp pop_return_path(conn) do
    {get_session(conn, :return_to), delete_session(conn, :return_to)}
  end
end
