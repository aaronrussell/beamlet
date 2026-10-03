defmodule Beamlet.Router do
  @moduledoc """
  The router a host forwards to, which puts a beamlet on the web.

  One line in the host's router:

      forward "/", Beamlet.Router

  It goes last in the host's router and at the root. Last, because a
  forward at `/` matches everything after it, so the host's own
  routes win by coming first. At the root, because a LiveView page's
  connected mount re-matches the full browser URL against the router
  that served it, and a forward at a prefix strips that prefix from
  what the router sees. The routes agents mount are served at the
  root, or under the prefix `config :beamlet, :web` names, which the
  router generated from them carries instead.

  ## The paths

  Everything the beamlet owns lives under one segment, `/beamlet`,
  which an agent can never mount under:

    * `/beamlet/mcp`, the MCP server (`Beamlet.MCP.Server`), behind
      the token check.
    * `/beamlet/login` and `/beamlet/logout`, the sign-in and the
      sign-out.
    * `/beamlet`, the home page, behind the login.
    * `/beamlet/authorize`, the OAuth consent page, behind the login,
      and `/beamlet/token`, which clients post to directly, so no
      session and no CSRF check (`Beamlet.OAuth`).
    * `/beamlet/live`, `/beamlet/app/live` and `/beamlet/assets`, on
      the host's endpoint (below).

  The one exception is the pair of OAuth discovery documents, which
  the specs fix under `/.well-known` at the root; they are exact
  paths, matched ahead of the forward. Any other path under
  `/beamlet` answers 404 here, whatever the route table holds.
  Everything else forwards to the router generated from the routes
  agents mount, so `/` is an agent's to build and answers 404 until
  one does.

  The sign-in, the consent page and the home page are the app, the
  beamlet's own inner app, as against the pages agents build. The app
  keeps its own session in its own cookie, scoped to `/beamlet`
  (`Beamlet.Web.Auth`), which this router plugs in place of the
  endpoint's, and its pages connect to their own LiveView socket.
  Agent pages never receive the app's cookie or its session, and
  nothing they write to theirs signs anyone in.

  ## What the host carries

  The pages agents build are LiveViews, and the endpoint serving them
  needs what any LiveView app's endpoint has. This is the whole list,
  and the standalone server's endpoint is the worked example. In the
  router, the forward above as the last route. The endpoint:

      defmodule MyAppWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :my_app

        @session_options [store: :cookie, key: "_my_app_key", signing_salt: "...", same_site: "Lax"]

        socket "/beamlet/live", Phoenix.LiveView.Socket,
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
      end

  Each piece, and why:

    * The socket at `/beamlet/live` is the one agent pages connect to,
      under the endpoint's session.
    * The socket at `/beamlet/app/live` is the app's, decoding the
      app's own cookie.
    * `Beamlet.Assets` goes before the parsers, where `Plug.Static`
      usually goes, and serves the LiveView JavaScript and the app's
      stylesheet under `/beamlet/assets`.
    * The JSON parser is for controller routes; the urlencoded one for
      the sign-in form, the token endpoint and the forms agent pages
      post. No multipart parser: it writes uploads to the system temp
      dir, where agent code cannot read them.
    * `Plug.MethodOverride` after the parsers, so a form's `_method`
      field reaches the PUT, PATCH and DELETE routes agents mount.
    * `Plug.Session` is the session agent pages fetch: their CSRF
      token, their flash and whatever an agent's app keeps there. It
      does not carry the sign-in. Behind a proxy that terminates TLS,
      add `plug Plug.RewriteOn, [:x_forwarded_proto]` ahead of it so
      both session cookies are marked secure.

  > #### Nothing may fetch the session before the forward {: .warning}
  >
  > The app's session stays apart only while a request reaches this
  > router with its session unfetched. A plug in the endpoint, or a
  > pipeline in the host's router ahead of the forward, that calls
  > `fetch_session/2` leaves the endpoint's session merged over the
  > app's and both cookies written from the one map, so a sign-in
  > lands in the cookie agent routes read and write. The standalone
  > server fetches nothing early.

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

  `web: [endpoint: ...]` names the endpoint the routes are served
  through (`Beamlet.Config`). `pubsub_server` lets a page subscribe
  through `Host.PubSub`. `render_errors` names an error view,
  `Beamlet.Web.ErrorView` or the host's own. `filter_parameters`
  keeps the sign-in's password and the token endpoint's secrets out
  of the request log.
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
