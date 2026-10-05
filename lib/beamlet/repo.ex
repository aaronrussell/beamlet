defmodule Beamlet.Repo do
  @moduledoc """
  The beamlet's own database: the owner, their sessions, the tokens
  and the routes agents mount.

  It lives at `db/beamlet.db` in the data dir. The beamlet creates
  and migrates it when it starts, so there is no `mix ecto.migrate`
  step. Agent code has no way to write it: what agents build as data
  goes in `Host.Repo`, the agent database.

  To tune it, pass adapter options in config:

      config :beamlet, Beamlet.Repo, pool_size: 10

  It takes any `Ecto.Adapters.SQLite3` option except `:database` and
  `:journal_mode`, which the beamlet sets itself. `Host.Repo`, the
  agent database, takes options under its own name in the same way.
  """

  use Ecto.Repo, otp_app: :beamlet, adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_context, config) do
    config =
      config
      |> Keyword.put(:database, Beamlet.Config.beamlet_db_file())
      |> Keyword.put(:journal_mode, :wal)

    {:ok, config}
  end
end
