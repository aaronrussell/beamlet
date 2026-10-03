defmodule Beamlet.Repo do
  @moduledoc """
  The system database, which holds the owner, their sessions and the
  tokens.

  It lives at `db/beamlet.db` in the data dir. The beamlet creates
  and migrates it when it starts, so there is no `mix ecto.migrate`
  step.

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
      |> Keyword.put(:database, Beamlet.Config.system_db_file())
      |> Keyword.put(:journal_mode, :wal)

    {:ok, config}
  end
end
