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

  Everything the beamlet owns lives under one segment, `/beamlet`,
  which an agent can never mount under: the MCP server at
  `/beamlet/mcp` (`Beamlet.MCP.Plug`), the sign-in at
  `/beamlet/login` and `/beamlet/logout` (`Beamlet.Web.SessionController`),
  the home page at `/beamlet` (`Beamlet.Web.HomeLive`, behind the
  login), and on the host's endpoint the socket and asset paths
  below. Everything else forwards to the router generated from the
  routes agents mount (`Beamlet.Routes`), so `/` is an agent's to
  build and answers 404 until one does.

  ## What the host carries

  The pages agents build are LiveViews, and the endpoint serving them
  needs what any LiveView app's endpoint has. This is the whole list
  of integration points; `Beamlet.TestEndpoint` in the library's test
  support is it written down, and the standalone server in `server/`
  is a copy.

  In the router:

    * `forward "/", Beamlet.Router` as the last route.

  In the endpoint:

    * The LiveView socket at `/beamlet/live`, the path the root
      layout (`Beamlet.Web.Layouts`) connects to:
      `socket "/beamlet/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]`.
    * `plug Beamlet.Assets` before the parsers, serving the LiveView
      JavaScript under `/beamlet/assets` from the deps' precompiled
      bundles.
    * `Plug.Parsers` with the JSON and urlencoded parsers: JSON for
      controller routes, urlencoded for the sign-in form.
    * `Plug.Session`, which carries the sign-in and which the browser
      pipeline fetches. Behind a proxy that terminates TLS, add
      `plug Plug.RewriteOn, [:x_forwarded_proto]` ahead of it so the
      session cookie is marked secure.

  In config:

    * `config :beamlet, web: [endpoint: MyAppWeb.Endpoint]`, naming the
      endpoint the routes are served through (`Beamlet.Config`).
    * `pubsub_server: Beamlet.PubSub` on the endpoint, so a page can
      subscribe through `Host.PubSub`.
    * `render_errors` on the endpoint naming an error view;
      `Beamlet.Web.ErrorView` is a plain one, or the host's own.
  """

  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Beamlet.Web.Auth, only: [fetch_current_user: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Beamlet.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  scope "/beamlet", Beamlet.Web do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    post "/logout", SessionController, :delete

    live_session :beamlet, on_mount: [{Beamlet.Web.Auth, :require_login}] do
      live "/", HomeLive
    end
  end

  forward "/beamlet/mcp", Beamlet.MCP.Plug
  forward "/", Beamlet.DynamicRouter
end
