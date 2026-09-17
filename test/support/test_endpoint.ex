defmodule Beamlet.TestEndpoint do
  @moduledoc """
  The endpoint the suite serves a beamlet's routes through, and the
  written form of what a host's endpoint must carry (`Beamlet.Router`):
  the session, the LiveView socket at `/_live`, the LiveView
  JavaScript from the deps' bundles under `/_assets`, the JSON parser,
  and a router whose last line forwards to `Beamlet.Router` at the
  root. `Beamlet.Case` starts it after the beamlet.
  """

  use Phoenix.Endpoint, otp_app: :beamlet

  @session_options [
    store: :cookie,
    key: "_beamlet_test_key",
    signing_salt: "beamlet-test",
    same_site: "Lax"
  ]

  socket "/_live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/_assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.mjs phoenix.mjs.map)

  plug Plug.Static,
    at: "/_assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.esm.js phoenix_live_view.esm.js.map)

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug Plug.Session, @session_options
  plug Beamlet.TestRouter
end
