defmodule Beamlet.Tables do
  @moduledoc false

  # Beamlet's own tables in the agent database: the key/value store
  # behind Host.KV and the route table behind Beamlet.Routes. They
  # sit beside the agent's tables because the data is the agent's, so
  # a KV write inside a Host.Repo.transaction lands with the rows it
  # tracks and wiping the agent database wipes them too. The
  # double-underscore name marks them as furniture rather than
  # migrated tables: outside the agent's migration history, which
  # Ecto tracks in schema_migrations, and outside the system
  # database's.
  #
  # The furniture is versioned through PRAGMA user_version, the
  # integer SQLite keeps in the file header, so an upgrade never
  # needs a fresh data dir: @steps is an ordered list of up-only
  # steps, the file's version is how many have run, and boot runs
  # the ones above it in order, each with its version bump inside
  # one transaction so a crash halfway reruns the step next time. A
  # file above the current version was written by a newer Beamlet
  # and fails the boot, since up-only steps have nothing to run and
  # no way back. A synchronous child right after Host.Repo, so a
  # failure fails the boot the way the system database's migrator
  # does. Raw SQL on Host.Repo can set user_version too; the policy
  # guards against accident, not adversaries.
  #
  # The route table's unique constraint is unnamed: ecto_sqlite3
  # derives the constraint name __routes_verb_path_index from the
  # column list in SQLite's error, and the changeset names that.

  require Logger

  @steps [
    [
      "CREATE TABLE __kv (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID",
      """
      CREATE TABLE __routes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        verb TEXT NOT NULL,
        path TEXT NOT NULL,
        module TEXT NOT NULL,
        action TEXT,
        principal TEXT NOT NULL,
        inserted_at TEXT NOT NULL,
        UNIQUE (verb, path)
      )
      """
    ]
  ]

  @current length(@steps)

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :upgrade, []}}

  @spec current_version() :: pos_integer()
  def current_version, do: @current

  @spec version() :: non_neg_integer()
  def version do
    %{rows: [[version]]} = Host.Repo.query!("PRAGMA user_version")
    version
  end

  @spec upgrade() :: :ignore
  def upgrade do
    case version() do
      @current ->
        :ignore

      from when from < @current ->
        @steps
        |> Enum.with_index(1)
        |> Enum.drop(from)
        |> Enum.each(&run_step/1)

        :ignore

      from ->
        raise "the agent database is at furniture version #{from} and this Beamlet knows " <>
                "only #{@current}: it was last run by a newer Beamlet, so upgrade Beamlet " <>
                "or restore the data dir from a backup"
    end
  end

  defp run_step({statements, to}) do
    Host.Repo.transaction(fn ->
      Enum.each(statements, &Host.Repo.query!/1)
      Host.Repo.query!("PRAGMA user_version = #{to}")
    end)

    Logger.info("agent database furniture upgraded to version #{to}")
  end
end
