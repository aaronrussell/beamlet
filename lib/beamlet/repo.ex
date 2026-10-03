defmodule Beamlet.Repo do
  @moduledoc """
  The system database: what Beamlet itself keeps about a beamlet,
  the owner, their sessions and the tokens, apart from anything
  agents build.

  Lives at `db/beamlet.db` under the data dir and is migrated at boot
  from this package's priv dir, so an embedding host never runs a
  migration step for it. Agent code never reaches it; what agents
  build goes in the agent database, `Host.Repo`.

  Adapter options go under its own key, as for any Ecto repo. The
  path is derived from the data dir, never configured:

      config :beamlet, Beamlet.Repo, pool_size: 5
  """

  use Ecto.Repo, otp_app: :beamlet, adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_context, config) do
    config =
      config
      |> Keyword.put(:database, Beamlet.Config.system_db_file())
      |> Keyword.put(:journal_mode, :wal)

    {:ok, config}
  end
end
