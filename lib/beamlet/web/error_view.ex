defmodule Beamlet.Web.ErrorView do
  @moduledoc """
  Plain error responses for a host's endpoint: the status message as
  text for HTML requests and as `{"errors": {"detail": ...}}` for
  JSON. A miss under `Beamlet.Router` is a 404 rendered here, and
  since `/` is one until an agent mounts something there, the HTML
  404 says where the beamlet has its own pages.

      config :my_app, MyAppWeb.Endpoint,
        render_errors: [formats: [html: Beamlet.Web.ErrorView, json: Beamlet.Web.ErrorView], layout: false]

  A host with error pages of its own keeps them.
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
