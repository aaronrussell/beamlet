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

  Configuration is application config (`Beamlet.Config`); the start
  options carry nothing yet. Starting checks the configured data dir
  exists and builds the declared policies, and fails the boot loudly
  when the dir is missing or a policy is bad. One beamlet runs per
  VM.

  `prepare!/0` is the part of starting that happens before any child
  runs: the data dir check and the database files. It is public so the
  operator CLI (`Beamlet.CLI`) can bring up the system database on its
  own without starting a beamlet.
  """

  use Supervisor

  alias Beamlet.Config

  @typedoc "Options accepted by `start_link/1`. None yet."
  @type option :: {atom(), term()}

  @doc "Starts a beamlet, supervising everything it needs to run."
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks the data dir exists and creates both database files in WAL
  mode, without starting anything.

  `start_link/1` calls this before the children start; `Beamlet.CLI`
  calls it before starting the system repo alone. Raises when the
  data dir is missing.
  """
  @spec prepare!() :: :ok
  def prepare! do
    ensure_data_dir!()
    Enum.each([Beamlet.Repo, Host.Repo], &ensure_database!/1)
  end

  @impl true
  def init(_opts) do
    prepare!()

    children = [
      Beamlet.Policies,
      Beamlet.Repo,
      Host.Repo,
      {Ecto.Migrator, repos: [Beamlet.Repo]},
      {Beamlet.MCP.Server, transport: {:streamable_http, start: true}, request_timeout: 60_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp ensure_data_dir! do
    dir = Config.data_dir!()

    unless File.dir?(dir) do
      raise ArgumentError,
            "config :beamlet, :data_dir does not exist: #{dir} (create or mount it before starting)"
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
