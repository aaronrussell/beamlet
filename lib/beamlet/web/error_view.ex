defmodule Beamlet.Web.ErrorView do
  @moduledoc """
  A plain error view for your endpoint.

      config :my_app, MyAppWeb.Endpoint,
        render_errors: [
          formats: [html: Beamlet.Web.ErrorView, json: Beamlet.Web.ErrorView],
          layout: false
        ]

  It renders the status message as text, or as
  `{"errors": {"detail": ...}}` for JSON. Its 404 page points to
  `/beamlet`, since `/` answers 404 until an agent builds something
  there. Your own error view works too.
  """

  @doc "Renders the response for an error template such as `\"404.html\"` or `\"500.json\"`."
  @spec render(String.t(), map()) :: String.t() | map()
  def render("404.html", _assigns) do
    "Not Found. Nothing is mounted at this path; your beamlet has its own pages at /beamlet."
  end

  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)

    if String.ends_with?(template, ".json"),
      do: %{errors: %{detail: message}},
      else: message
  end
end
