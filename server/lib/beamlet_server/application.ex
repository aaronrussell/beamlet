defmodule BeamletServer.Application do
  @moduledoc false

  # Starts the beamlet, then the endpoint that serves it. Beamlet
  # comes first so its routes, policies and pubsub exist before the
  # first request.
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Beamlet,
      BeamletServer.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BeamletServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
