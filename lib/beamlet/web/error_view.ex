defmodule Beamlet.Web.ErrorView do
  @moduledoc """
  A plain error view for your endpoint.

      config :my_app, MyAppWeb.Endpoint,
        render_errors: [
          formats: [html: Beamlet.Web.ErrorView, json: Beamlet.Web.ErrorView],
          layout: false
        ]

  It renders the status message as text, or as
  `{"errors": {"detail": ...}}` for JSON. Your own error view works
  too.
  """

  @doc "Renders the response for an error template such as `\"404.html\"` or `\"500.json\"`."
  @spec render(String.t(), map()) :: String.t() | map()
  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)

    if String.ends_with?(template, ".json"),
      do: %{errors: %{detail: message}},
      else: message
  end
end
