defmodule Beamlet.Web.HomeLive do
  @moduledoc false

  # The home page at /beamlet, behind the login: a stub showing who
  # is signed in until the setup page replaces it (roadmap 0.1 step
  # 4). The sign-out is a plain form: the layout serves no
  # phoenix_html JavaScript, so a data-method link would not work.

  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "beamlet")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto mt-16 max-w-sm px-4">
      <h1 class="text-2xl font-semibold">beamlet</h1>
      <p id="signed-in" class="mt-4">Signed in as {@current_user.name}.</p>
      <.form for={%{}} as={:none} action="/beamlet/logout" method="post" id="logout-form" class="mt-6">
        <button type="submit" class="rounded border px-4 py-2">Sign out</button>
      </.form>
    </main>
    """
  end
end
