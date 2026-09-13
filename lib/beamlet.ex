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

  One beamlet runs per VM.
  """

  use Supervisor

  @typedoc "Options accepted by `start_link/1`. None yet."
  @type option :: {atom(), term()}

  @doc "Starts a beamlet, supervising everything it needs to run."
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end
end
