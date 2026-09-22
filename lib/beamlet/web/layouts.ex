defmodule Beamlet.Web.Layouts do
  @moduledoc """
  The layouts pages on a beamlet render inside: one root for the
  pages agents build, one for the beamlet's own.

  Both roots carry the wiring a LiveView page needs: the CSRF token,
  the LiveView JavaScript loaded as ES modules from the paths the
  host's endpoint serves them at (`Beamlet.Assets`), and the socket
  connection at `/beamlet/live`. They differ in how a page is styled.

  `root/1` is for agent pages, which `Beamlet.Routes` puts on every
  route agents mount. It loads Tailwind from its CDN, so a page can be
  styled with utility classes and no build step, and says nothing
  about how the page looks. Styling needs the internet; accepted for a
  substrate with no bundler.

  `beamlet/1` is for the beamlet's own pages, the sign-in, the consent
  page and the home page. It links the stylesheet built from
  `assets/css/beamlet.css` and shipped in `priv/static`, so those
  pages need nothing from the internet. `app/1` is the inner layout
  the signed-in pages render inside: the header naming the beamlet
  and the person, with the sign-out.
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  embed_templates "layouts/*"

  @doc """
  The inner layout for the beamlet's own signed-in pages: the header
  with the signed-in name and the sign-out, then the page.
  """
  attr :current_user, Beamlet.User, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-zinc-200">
      <div class="mx-auto flex max-w-2xl items-center justify-between px-4 py-3 text-sm">
        <a href="/beamlet" class="font-semibold">beamlet</a>
        <div class="flex items-center gap-3 text-zinc-500">
          <span id="signed-in">Signed in as {@current_user.name}.</span>
          <.form for={%{}} as={:none} action="/beamlet/logout" method="post" id="logout-form">
            <button type="submit" class="underline">Sign out</button>
          </.form>
        </div>
      </div>
    </header>
    <main class="mx-auto max-w-2xl px-4 py-10">
      {render_slot(@inner_block)}
    </main>
    """
  end
end
