defmodule Beamlet.Router do
  @moduledoc """
  The router your app forwards to, which serves the beamlet.

  Add it as the last route in your router, at the root:

      forward "/", Beamlet.Router

  Last, so your own routes win. At the root, because LiveView pages
  match the full URL and break under a forward at a prefix. To serve
  the routes agents mount under a path, set `:prefix` in
  `Beamlet.Config` instead.

  The beamlet keeps its own pages under `/beamlet`, where agents can
  never mount a route:

  * `/beamlet/mcp` - the MCP server (`Beamlet.MCP.Server`).
  * `/beamlet` - the home page, behind the sign-in.
  * `/beamlet/login` and `/beamlet/logout` - signing in and out.
  * `/beamlet/authorize` and `/beamlet/token` - OAuth
    (`Beamlet.OAuth`).

  It also answers the two OAuth documents under `/.well-known`. Every
  other path goes to the routes agents mount, so `/` answers 404
  until an agent builds something there.

  ## What your endpoint needs

  Agent pages are LiveViews, so your endpoint needs what any LiveView
  app has, plus a socket for the beamlet's own pages:

      socket "/beamlet/agent/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [session: @session_options]]

      socket "/beamlet/app/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [session: {Beamlet.Web.Auth, :session_options, []}]]

      plug Beamlet.Assets

      plug Plug.Parsers,
        parsers: [:urlencoded, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library()

      plug Plug.MethodOverride
      plug Plug.Session, @session_options
      plug MyAppWeb.Router

  * `/beamlet/agent/live` is the socket agent pages connect to, with your
    endpoint's session.
  * `/beamlet/app/live` is the socket the beamlet's own pages connect
    to, with their own session.
  * `Beamlet.Assets` serves the LiveView JavaScript and the
    beamlet's stylesheet. It goes before the parsers.
  * `Plug.Parsers` leaves out multipart. It writes uploads to the
    system temp dir, where agent code cannot read them.
  * `Plug.MethodOverride` lets agent forms reach their PUT, PATCH and
    DELETE routes.
  * Behind a proxy that terminates TLS, add
    `plug Plug.RewriteOn, [:x_forwarded_proto]` before `Plug.Session`,
    so the session cookies are marked secure.

  And in config:

      config :beamlet, web: [endpoint: MyAppWeb.Endpoint]

      config :my_app, MyAppWeb.Endpoint,
        pubsub_server: Beamlet.PubSub,
        render_errors: [
          formats: [html: Beamlet.Web.ErrorView, json: Beamlet.Web.ErrorView],
          layout: false
        ]

      config :phoenix, :filter_parameters,
        ["password", "code", "code_verifier", "refresh_token"]

  `pubsub_server` lets agent pages subscribe through `Host.PubSub`.
  `Beamlet.Web.ErrorView` is a plain error view, and your own works
  too. The filtered parameters keep the sign-in's password and the
  OAuth secrets out of the request log.

  The standalone server's
  [endpoint](https://github.com/aaronrussell/beamlet/blob/main/server/lib/beamlet_server/endpoint.ex)
  is a worked example.

  > #### Nothing may fetch the session before the forward {: .warning}
  >
  > The beamlet's pages swap in their own session as the request
  > reaches this router. If a plug in your endpoint or router fetches
  > the session first, the owner's sign-in lands in your endpoint's
  > session, which agent pages can read and write.
  """

  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Beamlet.Web.Auth, only: [fetch_current_user: 2, require_auth: 2]

  @doc false
  pipeline :browser do
    plug :accepts, ["html"]
    plug Plug.Session, Beamlet.Web.Auth.session_options()
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Beamlet.Web.Layouts, :app}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  @doc false
  pipeline :auth do
    plug :require_auth
  end

  # 1. Beamlet UI routes

  scope "/beamlet", Beamlet.Web do
    pipe_through :browser

    post "/login", SessionController, :create
    post "/logout", SessionController, :delete

    live_session :login, on_mount: [{Beamlet.Web.Auth, :fetch_current_user}] do
      live "/login", SessionLive
    end

    live_session :beamlet, on_mount: [{Beamlet.Web.Auth, :require_auth}] do
      live "/", HomeLive
    end
  end

  # 2. OAuth routes

  scope "/.well-known", Beamlet.OAuth do
    get "/oauth-protected-resource", MetadataController, :protected_resource
    get "/oauth-protected-resource/beamlet/mcp", MetadataController, :protected_resource
    get "/oauth-authorization-server", MetadataController, :authorization_server
  end

  scope "/beamlet", Beamlet.OAuth do
    pipe_through [:browser, :auth]

    live_session :authorize, on_mount: [{Beamlet.Web.Auth, :require_auth}] do
      live "/authorize", AuthorizeLive
    end
  end

  scope "/beamlet", Beamlet.OAuth do
    post "/token", TokenController, :create
  end

  # 3. MCP and Dynamic Router forwards

  forward "/beamlet/mcp", Beamlet.MCP.Plug
  match :*, "/beamlet/*path", Beamlet.Web.NotFound, []
  forward "/", Beamlet.DynamicRouter
end
