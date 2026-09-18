defmodule BeamletServer.Application do
  @moduledoc false
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

  @impl true
  def config_change(changed, _new, removed) do
    BeamletServer.Endpoint.config_change(changed, removed)
    :ok
  end
end
