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

  ## What the host carries

  The pages agents build are LiveViews, and the endpoint serving them
  needs what any LiveView app's endpoint has. This is the whole list
  of integration points; `Beamlet.TestEndpoint` in the library's test
  support is it written down, and the standalone server in `server/`
  is a copy.

  In the router:

    * `forward "/", Beamlet.Router` as the last route.

  In the endpoint:

    * The LiveView socket at `/_live`, the path the root layout
      (`Beamlet.Layouts`) connects to:
      `socket "/_live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]`.
    * `plug Beamlet.Assets` before the parsers, serving the LiveView
      JavaScript under `/_assets` from the deps' precompiled bundles.
    * `Plug.Parsers` with the JSON parser, for controller routes.
    * `Plug.Session`, since the browser pipeline fetches the session.

  In config:

    * `config :beamlet, web: [endpoint: MyAppWeb.Endpoint]`, naming the
      endpoint the routes are served through (`Beamlet.Config`).
    * `pubsub_server: Beamlet.PubSub` on the endpoint, so a page can
      subscribe through `Host.PubSub`.
    * `render_errors` on the endpoint naming an error view;
      `Beamlet.ErrorView` is a plain one, or the host's own.
  """

  use Phoenix.Router, helpers: false

  forward "/_mcp", Beamlet.MCP.Plug
  forward "/", Beamlet.DynamicRouter
end
