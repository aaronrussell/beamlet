defmodule Beamlet.Tables do
  @moduledoc false

  # Beamlet's own tables in the agent database: the key/value store
  # behind Host.KV and the route table behind Beamlet.Routes. They
  # sit beside the agent's tables because the data is the agent's, so
  # a KV write inside a Host.Repo.transaction lands with the rows it
  # tracks and wiping the agent database wipes them too. The
  # double-underscore name marks them as furniture rather than
  # migrated tables: created here at boot outside the agent's
  # migration history, and recreated at the next boot if agent code
  # drops one. A synchronous child right after Host.Repo, so a
  # failure fails the boot the way the system database's migrator
  # does; a beamlet without these tables would turn every Host.KV
  # call into an error that reads as an agent bug.
  #
  # The route table's unique constraint is unnamed: ecto_sqlite3
  # derives the constraint name __routes_verb_path_index from the
  # column list in SQLite's error, and the changeset names that.

  @statements [
    "CREATE TABLE IF NOT EXISTS __kv (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID",
    """
    CREATE TABLE IF NOT EXISTS __routes (
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

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :create, []}}

  @spec create() :: :ignore
  def create do
    Enum.each(@statements, &Host.Repo.query!/1)
    :ignore
  end
end
