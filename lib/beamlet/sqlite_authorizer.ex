defmodule Beamlet.SQLiteAuthorizer do
  @moduledoc """
  The SQLite authorizer on the agent database's connections.

  Raw SQL is granted on `Host.Repo`; what it must not reach is the
  rest of the disk. `ATTACH DATABASE 'path'` opens any file on the
  current connection, creating it when absent, and `VACUUM INTO
  'path'` attaches internally to copy the database anywhere.
  `install/2` puts SQLite's own authorizer on every pooled connection
  so those actions are refused at statement preparation; queries, DDL
  and `PRAGMA` are untouched. `Host.Repo.init/2` pins it as the
  pool's `:after_connect` hook: a property of the beamlet, not
  operator configuration.
  """
  require DBConnection.Holder
  alias DBConnection.Holder

  # `:after_connect` hands us a `DBConnection.t()`; the handle lives in the pool
  # holder's ETS record, reached here through DBConnection's private record
  # layout.
  #
  # The intended replacement is an Exqlite connect option (`authorizer:
  # [...]`, calling `set_authorizer` in `Exqlite.Connection.connect/1`);
  # when it lands, this hook becomes one config line.

  @doc """
  Installs an authorizer denying `deny_list` on the connection's
  SQLite handle. `deny_list` is the action atoms
  `Exqlite.Sqlite3.set_authorizer/2` accepts, e.g. `[:attach, :detach]`.
  """
  @spec install(DBConnection.t(), [atom()]) :: :ok
  def install(%DBConnection{pool_ref: pool_ref}, deny_list) do
    Holder.pool_ref(holder: holder) = pool_ref

    case :ets.lookup_element(holder, :conn, Holder.conn(:state) + 1) do
      %Exqlite.Connection{db: db} ->
        :ok = Exqlite.Sqlite3.set_authorizer(db, deny_list)

      other ->
        raise "expected the pool holder to carry an Exqlite.Connection, got: " <>
                "#{inspect(other)} — the agent database must not start without " <>
                "its SQLite authorizer"
    end
  end
end
