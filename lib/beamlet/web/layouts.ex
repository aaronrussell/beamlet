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
  `assets/css/beamlet.css` and shipped in `priv/static`. Inside it,
  `split/1` is the layout for the pages a person arrives at from
  elsewhere, the sign-in and the consent page: a panel with the
  wordmark and a tagline beside the form. `app/1` is the layout the
  signed-in pages render inside: the top bar naming the beamlet and
  the person, with the sign-out.
  """

  use Phoenix.Component

  import Beamlet.Web.Components
  import Phoenix.Controller, only: [get_csrf_token: 0]

  embed_templates "layouts/*"

  @doc """
  The layout for the sign-in and consent pages: the wordmark, the
  tagline and the beamlet's address in a panel, the form beside it.
  On a narrow screen the panel becomes a band above the form.
  """
  attr :tagline, :string, required: true
  slot :aside
  slot :inner_block, required: true

  def split(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col bg-card md:flex-row">
      <aside class="
        flex flex-none flex-col gap-6 border-b border-line bg-page bg-dots px-6 py-8
        md:w-1/3 md:min-w-[352px] md:justify-between md:border-b-0 md:border-r md:px-8 md:py-12">
        <.wordmark />
        <div>
          <p class="max-w-[16ch] font-display text-2xl font-semibold leading-[1.06] tracking-display text-strong mb-4 md:text-3xl">
            {@tagline}
          </p>
          {render_slot(@aside)}
        </div>
        <p class="hidden font-mono text-2xs lowercase tracking-label text-faint md:block">
          {address()}
        </p>
      </aside>
      <div class="flex flex-1 flex-col justify-center px-6 py-8 md:px-8 md:py-12">
        <div class="w-full max-w-2xl mx-auto pb-20 md:pb-0">
          {render_slot(@inner_block)}
        </div>
      </div>
      <p class="px-6 pb-6 font-mono text-2xs uppercase tracking-label text-faint md:hidden">
        {address()}
      </p>
    </div>
    """
  end

  @doc """
  The layout for the beamlet's own signed-in pages: the top bar with
  the wordmark, the beamlet's host, the signed-in name and the
  sign-out, then the page.
  """
  attr :current_user, Beamlet.User, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="flex h-[52px] items-center gap-4 border-b border-line bg-card px-5">
      <a href="/beamlet" class="no-underline"><.wordmark class="text-[18px]" /></a>
      <span class="ml-1 hidden border-l border-hairline pl-3.5 font-mono text-xs text-muted sm:inline">
        {host()}
      </span>
      <span class="flex-1"></span>
      <span id="signed-in" class="font-mono text-xs text-muted">
        Signed in as {@current_user.name}.
      </span>
      <.form for={%{}} as={:none} action="/beamlet/logout" method="post" id="logout-form">
        <.button type="submit" variant="ghost" size="sm">Sign out</.button>
      </.form>
    </header>
    <main class="mx-auto max-w-[860px] px-5 pb-16 pt-9 md:px-10">
      {render_slot(@inner_block)}
    </main>
    """
  end

  defp address, do: "#{host()} · v#{Application.spec(:beamlet, :vsn)}"

  defp host do
    uri = URI.parse(Beamlet.OAuth.issuer())
    if uri.port in [80, 443], do: uri.host, else: "#{uri.host}:#{uri.port}"
  end
end
