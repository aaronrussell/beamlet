defmodule Beamlet.Layouts do
  @moduledoc """
  The root layout the pages agents build render inside.

  It carries the wiring a LiveView page needs and nothing about how
  the page looks: the CSRF token, the LiveView JavaScript loaded as
  ES modules from the paths the host's endpoint serves them at
  (`Beamlet.Router` lists them), the socket connection at `/_live`,
  and Tailwind from its CDN, so a page can be styled with utility
  classes and no build step. Styling needs the internet; accepted for
  a substrate with no bundler.
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  embed_templates "layouts/*"
end
