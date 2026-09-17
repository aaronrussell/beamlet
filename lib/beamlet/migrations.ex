defmodule Beamlet.Migrations do
  @moduledoc false

  # The agent database's migration history: the join between the
  # migration modules the code server holds (Beamlet.Code.manifest/0,
  # those filed with a version) and Ecto's own schema_migrations
  # table in Host.Repo, which Ecto creates on first read. Host.Migrator
  # runs the verbs over this; the code server reads applied_versions/0
  # for the version floor and the pending rule.
  #
  # An applied version whose module is gone, a hand deletion or a git
  # rewind of the code dir, is an orphan: it stays in the table, the
  # listing marks it, rollback refuses to pop past it (Ecto would
  # otherwise undo the migration beneath), and the next version is
  # assigned past it.

  import Ecto.Query, only: [from: 2]

  @type entry :: %{
          version: pos_integer(),
          module: module() | nil,
          applied_at: NaiveDateTime.t() | nil
        }

  @spec applied_versions() :: [pos_integer()]
  def applied_versions, do: Ecto.Migrator.migrated_versions(Host.Repo, log: false)

  @spec list() :: [entry()]
  def list do
    applied = applied_at_by_version()

    defined =
      for {mod, %{migration: version}} <- Beamlet.Code.manifest(), version != nil, into: %{} do
        {version, mod}
      end

    (Map.keys(defined) ++ Map.keys(applied))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn version ->
      %{version: version, module: defined[version], applied_at: applied[version]}
    end)
  end

  # applied_versions/0 first so Ecto has created the table before the
  # timestamp query reads it.
  defp applied_at_by_version do
    _versions = applied_versions()

    Host.Repo.all(
      from(m in "schema_migrations",
        select: {m.version, type(m.inserted_at, :naive_datetime)}
      )
    )
    |> Map.new()
  end
end
