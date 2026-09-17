defmodule Beamlet.Router do
  @moduledoc """
  The router a host forwards to, and the one line that puts a beamlet
  on the web:

      forward "/", Beamlet.Router

  It goes last in the host's router and at the root. Last, because a
  forward at `/` matches everything after it, so the host's own routes
  win by coming first. At the root, because a LiveView page's
  connected mount re-matches the full browser URL against the router
  that served it, and a forward at a prefix strips that prefix from
  what the router sees; the routes agents mount are served at the
  root, or under the prefix `config :beamlet, :web` names, and
  `Beamlet.Routes` bakes that prefix into the generated router
  instead.

  Two things live here. `/_mcp` is the MCP server (`Beamlet.MCP.Plug`),
  and everything else forwards to the router generated from the
  routes agents mount (`Beamlet.Routes`). A first path segment that
  starts with an underscore is the beamlet's, never an agent's:
  `/_mcp` here, and the socket and asset paths below on the host's
  endpoint.

  ## What the host's endpoint carries

  The pages agents build are LiveViews, and the endpoint serving them
  needs what any LiveView app's endpoint has. `Beamlet.TestEndpoint`
  in the library's test support is this list written down:

    * `Plug.Session`, since the browser pipeline fetches the session.
    * The LiveView socket at `/_live`:
      `socket "/_live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]`.
    * `Plug.Static` serving the LiveView JavaScript from the deps'
      precompiled bundles, which the root layout (`Beamlet.Layouts`)
      loads, so there is no asset pipeline to run:
      `at: "/_assets/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.mjs phoenix.mjs.map)`
      and `at: "/_assets/phoenix_live_view", from: {:phoenix_live_view, "priv/static"}, only: ~w(phoenix_live_view.esm.js phoenix_live_view.esm.js.map)`.
    * `Plug.Parsers` with the JSON parser, for controller routes.
    * `pubsub_server: Beamlet.PubSub` in the endpoint's config, so a
      page can subscribe through `Host.PubSub`.
    * `render_errors` naming an error view; `Beamlet.ErrorView` is a
      plain one, or the host's own.
  """

  use Phoenix.Router, helpers: false

  forward "/_mcp", Beamlet.MCP.Plug
  forward "/", Beamlet.DynamicRouter
end
