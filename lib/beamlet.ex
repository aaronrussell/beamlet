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
  exists and fails the boot loudly when it does not. One beamlet runs
  per VM.
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

  @impl true
  def init(_opts) do
    ensure_data_dir!()

    children = [
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
end
