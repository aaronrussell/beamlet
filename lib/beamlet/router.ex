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
  `/beamlet/login` (`Beamlet.Web.SessionLive`, posting to
  `Beamlet.Web.SessionController`, which also owns `/beamlet/logout`),
  the home page at `/beamlet` (`Beamlet.Web.HomeLive`, behind the
  login), the OAuth endpoints at `/beamlet/authorize` (behind the
  login too, `Beamlet.OAuth.AuthorizeLive`) and `/beamlet/token`
  (`Beamlet.OAuth.TokenController`, which clients post to directly, so
  no session and no CSRF check), and on the host's endpoint the
  socket and asset paths below. The one exception is the pair of
  OAuth discovery documents (`Beamlet.OAuth.MetadataController`),
  which the specs fix under `/.well-known` at the root; they are exact
  paths, matched ahead of the forward. Any other path under `/beamlet`
  answers 404 here, whatever the route table holds. Everything else
  forwards to the router generated from the routes agents mount
  (`Beamlet.Routes`), so `/` is an agent's to build and answers 404
  until one does.

  The sign-in, the consent page and the home page are the app, the
  beamlet's own inner app, as against the pages agents build. The app
  keeps its own session in its own cookie, scoped to `/beamlet`
  (`Beamlet.Web.Auth.session_options/0`), which this router's browser
  pipeline plugs in place of the endpoint's, and its pages connect to
  their own LiveView socket. Agent pages never receive the app's
  cookie or its session, and nothing they write to theirs signs
  anyone in.

  ## What the host carries

  The pages agents build are LiveViews, and the endpoint serving them
  needs what any LiveView app's endpoint has. This is the whole list
  of integration points; `Beamlet.TestEndpoint` in the library's test
  support is it written down, and the standalone server in `server/`
  is a copy.

  In the router:

    * `forward "/", Beamlet.Router` as the last route.

  In the endpoint:

    * The LiveView socket for agent pages at `/beamlet/live`, the
      path the `beamlet` layout (`Beamlet.Web.Layouts`) connects to:
      `socket "/beamlet/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]`.
    * The LiveView socket for the app at `/beamlet/app/live`, the
      path the `app` layout connects to, decoding the app's cookie:
      `socket "/beamlet/app/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: {Beamlet.Web.Auth, :session_options, []}]]`.
    * `plug Beamlet.Assets` before the parsers, serving the LiveView
      JavaScript and the beamlet's own stylesheet under
      `/beamlet/assets`.
    * `Plug.Parsers` with the JSON and urlencoded parsers: JSON for
      controller routes, urlencoded for the sign-in form.
    * `Plug.Session`, the session agent pages fetch: their CSRF
      token, their flash and whatever an agent's app keeps there. It
      does not carry the sign-in. Behind a proxy that terminates TLS,
      add `plug Plug.RewriteOn, [:x_forwarded_proto]` ahead of it so
      both session cookies are marked secure.

  In config:

    * `config :beamlet, web: [endpoint: MyAppWeb.Endpoint]`, naming the
      endpoint the routes are served through (`Beamlet.Config`).
    * `pubsub_server: Beamlet.PubSub` on the endpoint, so a page can
      subscribe through `Host.PubSub`.
    * `render_errors` on the endpoint naming an error view;
      `Beamlet.Web.ErrorView` is a plain one, or the host's own.
    * `config :phoenix, :filter_parameters, ["password", "code",
      "code_verifier", "refresh_token"]`, so the request log keeps
      neither the sign-in's password nor the token endpoint's secrets.
  """

  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Beamlet.Web.Auth, only: [fetch_current_user: 2, require_auth: 2]

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
