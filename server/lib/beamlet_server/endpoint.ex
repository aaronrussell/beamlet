defmodule BeamletServer.Endpoint do
  @moduledoc false

  # The server's endpoint, and the worked example of what a host's
  # endpoint carries for a beamlet: a LiveView socket for agent pages
  # under the host's session and one for the app under the app's own
  # (Beamlet.Web.Auth), Beamlet.Assets ahead of the parsers and the
  # router, and a parser list with no multipart. The router forwards
  # everything to Beamlet.Router.

  use Phoenix.Endpoint, otp_app: :beamlet_server

  @session_options [
    store: :cookie,
    key: "_beamlet_server_key",
    signing_salt: "uPoknILl",
    same_site: "Lax"
  ]

  socket "/beamlet/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  socket "/beamlet/app/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {Beamlet.Web.Auth, :session_options, []}]],
    longpoll: [connect_info: [session: {Beamlet.Web.Auth, :session_options, []}]]

  plug Plug.RewriteOn, [:x_forwarded_proto]

  plug Beamlet.Assets

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # No multipart parser: it writes uploads to the system temp dir,
  # where agent code cannot read them.
  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug BeamletServer.Router
end
