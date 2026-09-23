defmodule Beamlet.Web.SessionLive do
  @moduledoc false

  # The sign-in page at /beamlet/login. The form posts to
  # Beamlet.Web.SessionController, since a session cookie is written
  # on an HTTP response; this page only renders it and the flash the
  # controller sends back. A signed-in person is sent home.

  use Phoenix.LiveView

  import Beamlet.Web.Components

  alias Beamlet.User
  alias Beamlet.Web.Layouts

  @impl true
  def mount(_params, _session, %{assigns: %{current_user: %User{}}} = socket) do
    {:ok, redirect(socket, to: "/beamlet")}
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Sign in", form: to_form(%{}, as: :user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.split tagline="A little Elixir machine for your agents.">
      <h1 class="text-xl">Sign in</h1>

      <.flash :if={Phoenix.Flash.get(@flash, :error)} id="flash-error" kind="error">
        {Phoenix.Flash.get(@flash, :error)}
      </.flash>
      <.flash :if={Phoenix.Flash.get(@flash, :info)} id="flash-info" kind="info">
        {Phoenix.Flash.get(@flash, :info)}
      </.flash>

      <.form for={@form} action="/beamlet/login" id="login-form" class="mt-5 flex flex-col gap-4">
        <.input field={@form[:name]} label="Name" mono autocomplete="username" autofocus required />
        <.input
          field={@form[:password]}
          label="Password"
          type="password"
          autocomplete="current-password"
          required
        />
        <.button type="submit" variant="primary" size="lg" full>Sign in</.button>
      </.form>
    </Layouts.split>
    """
  end
end
