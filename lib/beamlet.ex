defmodule Beamlet do
  @moduledoc """
  Beamlet is a programmable Elixir code server for AI agents.

  An agent connects over MCP and works on your beamlet, a running
  Elixir application. It defines modules, runs code, and builds APIs
  and live dashboards on it. Most people run Beamlet as a standalone
  server, and [Getting started](getting-started.md) is the place to
  start.

  This module is what starts a beamlet, in the standalone server or
  inside your own app.

  ## Running a beamlet in your app

  > #### Your app is inside the boundary {: .warning}
  >
  > Agent code runs in the same VM as your application. Policies are
  > guardrails, not containment. Anyone holding a token can reach
  > whatever your application can: its modules, its processes and
  > its data. Embed a beamlet only where you would trust every token
  > holder with the whole app.

  Add `Beamlet` to your supervision tree, before your endpoint, so
  the beamlet is ready by the first request:

      children = [
        Beamlet,
        MyAppWeb.Endpoint
      ]

  Give it a data dir and name your endpoint:

      config :beamlet,
        data_dir: "/var/lib/my_app/beamlet",
        web: [endpoint: MyAppWeb.Endpoint]

  Then forward to `Beamlet.Router` as the last route in your router:

      forward "/", Beamlet.Router

  Your endpoint needs a few more things, two LiveView sockets among
  them. `Beamlet.Router` lists them all, and `Beamlet.Config` covers
  the other config keys.

  The boot fails with a message saying what to fix when the data dir
  is missing, a policy is invalid, git is not installed or no
  endpoint is named. Only one beamlet runs per VM.
  """

  use Supervisor

  alias Beamlet.Config

  @typedoc "Options accepted by `start_link/1`."
  @type option :: {:only, :system}

  @doc """
  Starts a beamlet, supervising everything it needs to run.

  ## Options

  * `:only` - `:system` starts just the policies and the system
    database, with nothing an agent reaches.
  """
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

  defp children(nil) do
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
      Beamlet.OAuth.Clients,
      Beamlet.OAuth.Codes,
      {Beamlet.MCP.Server, transport: {:streamable_http, start: true}}
    ]
  end

  defp children(other) do
    raise ArgumentError,
          "Beamlet.start_link only: accepts :system, got: #{inspect(other)}"
  end

  # The world the checked config points at: the data dir exists, the
  # migrations and the system database do, before any child runs. The
  # full boot also needs an endpoint to serve the routes through, the
  # files dir and the agent database; the system half touches nothing
  # an agent reaches.
  defp prepare!(only) do
    ensure_data_dir!()
    ensure_migrations!()
    ensure_database!(Beamlet.Repo)

    if only == nil do
      ensure_endpoint!()
      File.mkdir_p!(Config.files_dir())
      ensure_database!(Host.Repo)
    end
  end

  defp ensure_data_dir! do
    dir = Config.data_dir()

    unless File.dir?(dir) do
      raise ArgumentError,
            "config :beamlet, :data_dir does not exist: #{dir} (create or mount it before starting)"
    end
  end

  # Ecto.Migrator reads a missing dir as no migrations and boots, so
  # the first query fails instead, on a table that was never created.
  defp ensure_migrations! do
    path = Ecto.Migrator.migrations_path(Beamlet.Repo)

    unless File.dir?(path) do
      raise ArgumentError,
            "Beamlet's migrations are missing: #{path} (the release must carry " <>
              "the beamlet app's priv dir)"
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
