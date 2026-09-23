defmodule Beamlet.Repo do
  @moduledoc """
  The system database: what Beamlet itself keeps about a beamlet,
  users and tokens, apart from anything agents build.

  Lives at `db/beamlet.db` under the data dir and is migrated at boot
  from this package's priv dir, so an embedding host never runs a
  migration step for it. Adapter options go under
  `config :beamlet, Beamlet.Repo`; the path is derived, not
  configured.
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
