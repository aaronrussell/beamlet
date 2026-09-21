defmodule Beamlet.TestEndpoint do
  @moduledoc """
  The endpoint the suite serves a beamlet's routes through, and the
  written form of what a host's endpoint must carry (`Beamlet.Router`):
  the session, the LiveView socket at `/beamlet/live`,
  `Beamlet.Assets` for the LiveView JavaScript under
  `/beamlet/assets`, the JSON and urlencoded parsers, and a router
  whose last line forwards to `Beamlet.Router` at the root.
  `Beamlet.Case` starts it after the beamlet.
  """

  use Phoenix.Endpoint, otp_app: :beamlet

  @session_options [
    store: :cookie,
    key: "_beamlet_test_key",
    signing_salt: "beamlet-test",
    same_site: "Lax"
  ]

  socket "/beamlet/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Beamlet.Assets

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug Plug.Session, @session_options
  plug Beamlet.TestRouter
end
