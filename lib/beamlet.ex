defmodule Beamlet do
  @moduledoc """
  A beamlet's supervision tree.

  Beamlet is a library, not an OTP application: nothing starts until
  a host adds `Beamlet` to its own supervision tree. The standalone
  server does this in its application module; an embedding host does
  it wherever its boot ordering needs; a test does it with
  `start_supervised!/1` and gets a fresh beamlet per test.

      children = [
        {Beamlet, []},
        MyApp.Endpoint
      ]

  Configuration is application config (`Beamlet.Config`). Starting
  checks the configured data dir exists, builds the declared policies
  and loads the modules defined before (`Beamlet.Code`), and fails
  the boot loudly when the dir is missing, a policy is bad, git is
  not installed or no endpoint is configured. One beamlet runs per
  VM.

  The web surface, the pages and APIs agents build, is served by the
  host's own endpoint. The host names it in config, forwards to
  `Beamlet.Router` at the root as the last route of its router, and
  carries the few things the pages need, the LiveView socket among
  them; `Beamlet.Router` lists them.

      config :beamlet, web: [endpoint: MyAppWeb.Endpoint]

      forward "/", Beamlet.Router

  The beamlet's message bus is a `Phoenix.PubSub` named
  `Beamlet.PubSub`, which agent code reaches through `Host.PubSub`.
  A host's endpoint names it so LiveViews defined on the beamlet can
  subscribe and receive:

      config :my_app, MyAppWeb.Endpoint, pubsub_server: Beamlet.PubSub

  `only: :system` starts the system half alone: the policies and the
  system database, migrated. Nothing an agent reaches, no agent
  database and no MCP server. The operator CLI (`Beamlet.CLI`) uses it
  to manage users and tokens in a VM with no beamlet running:

      {:ok, pid} = Beamlet.start_link(only: :system)
  """

  use Supervisor

  alias Beamlet.Config

  @typedoc "Options accepted by `start_link/1`."
  @type option :: {:only, :system}

  @doc "Starts a beamlet, supervising everything it needs to run."
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Config.validate!()
    only = Keyword.get(opts, :only)
    children = children(only)
    prepare!(only)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp children(:system) do
    [
      Beamlet.Policies,
      Beamlet.Repo,
      {Ecto.Migrator, repos: [Beamlet.Repo]}
    ]
  end

  # The transport's request timeout answers "Server unavailable" and
  # leaves the request running, so a tool's own timeout must fire
  # first: eval's, or define's, which may wait a full compile behind
  # another define before its own (Beamlet.Code.define/5).
  defp children(nil) do
    define_timeout = Config.define()[:timeout]

    [
      Beamlet.Policies,
      Beamlet.Repo,
      {Ecto.Migrator, repos: [Beamlet.Repo]},
      Host.Repo,
      Beamlet.Tables,
      {Task.Supervisor, name: Beamlet.TaskSupervisor},
      {Phoenix.PubSub, name: Beamlet.PubSub},
      Beamlet.Code,
      Beamlet.Routes,
      {Beamlet.MCP.Server,
       transport: {:streamable_http, start: true},
       request_timeout: max(Config.eval()[:timeout], 2 * define_timeout + 5_000) + 5_000}
    ]
  end

  defp children(other) do
    raise ArgumentError,
          "Beamlet.start_link only: accepts :system, got: #{inspect(other)}"
  end

  # The world the checked config points at: the data dir exists, the
  # files dir and the database files do, before any child runs. The
  # full boot also needs an endpoint to serve the routes through; the
  # system half serves nothing.
  defp prepare!(only) do
    ensure_data_dir!()
    if only == nil, do: ensure_endpoint!()
    File.mkdir_p!(Config.files_dir())
    Enum.each([Beamlet.Repo, Host.Repo], &ensure_database!/1)
  end

  defp ensure_data_dir! do
    dir = Config.data_dir()

    unless File.dir?(dir) do
      raise ArgumentError,
            "config :beamlet, :data_dir does not exist: #{dir} (create or mount it before starting)"
    end
  end

  defp ensure_endpoint! do
    unless Config.web()[:endpoint] do
      raise ArgumentError,
            "config :beamlet, web: [endpoint: ...] is not set; name the endpoint that " <>
              "forwards to Beamlet.Router"
    end
  end

  # Pool connections opening a file not yet in WAL mode race to switch
  # it and log failed connects, so one connection creates it first.
  # The repo config must carry journal_mode: :wal for this to hold.
  defp ensure_database!(repo) do
    case repo.__adapter__().storage_up(repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end
  end
end
