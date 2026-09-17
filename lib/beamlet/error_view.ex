defmodule Beamlet.ErrorView do
  @moduledoc """
  Plain error responses for a host's endpoint: the status message as
  text for HTML requests and as `{"errors": {"detail": ...}}` for
  JSON. A miss under `Beamlet.Router` is a 404 rendered here.

      config :my_app, MyAppWeb.Endpoint,
        render_errors: [formats: [html: Beamlet.ErrorView, json: Beamlet.ErrorView], layout: false]

  A host with error pages of its own keeps them.
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
