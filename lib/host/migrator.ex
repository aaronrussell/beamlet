defmodule Host.Migrator do
  @moduledoc """
  Run the migrations you define against the agent database, and read
  their history.

  A migration is a module that uses `Ecto.Migration`, defined with
  the define tool like any other. Your beamlet files it with the next
  version number; it is *pending* until you run it from here. The
  loop is: define the migration, `migrate/0`, then define the
  `Ecto.Schema` module for the table it created and use it through
  `Host.Repo`.

      defmodule Shopping.CreateLists do
        @moduledoc "Creates the shopping lists table."
        use Ecto.Migration

        def change do
          create table(:shopping_lists) do
            add :name, :string, null: false
            timestamps(type: :utc_datetime)
          end
        end
      end

  Then, from eval: `Host.Migrator.migrate()`.

  `migrate/0` and `rollback/0` change the database, print what they
  applied or undid, and return `:ok`; `print_migrations/0` prints the
  history, version, module, applied or pending, and returns `:ok`.
  A failure raises with a teaching message. Inside a migration, query
  by table name and call `Host.Repo` by name after `flush()`; do not
  reference schema modules, which change while a migration is frozen
  history.

  To change a migration that has run, `rollback/0`, replace it and
  `migrate/0` again. SQLite cannot change a column's type or drop a
  constraint: create a new table, copy the rows with an insert from
  a select, drop the old table and rename the new one.
  """

  alias Beamlet.Migrations

  @doc """
  Applies every pending migration in version order, printing each
  one as it is applied. Nothing pending prints so. If one fails, the
  ones before it stay applied and the error names the one that
  failed; fix it with define (replace: true) and migrate again.
  """
  @spec migrate() :: :ok
  def migrate do
    case Enum.filter(Migrations.list(), &(&1.module != nil and &1.applied_at == nil)) do
      [] ->
        IO.puts("No pending migrations")

      pending ->
        Enum.each(pending, fn %{version: version, module: mod} ->
          up!(version, mod)
          IO.puts("Applied migration #{version} (#{inspect(mod)})")
        end)
    end

    :ok
  end

  @doc """
  Undoes the most recently applied migration and prints it. The
  migration is pending again: replace or remove it, or migrate to
  re-apply it. Call repeatedly to roll back further.
  """
  @spec rollback() :: :ok
  def rollback do
    case Migrations.list() |> Enum.filter(& &1.applied_at) |> List.last() do
      nil ->
        IO.puts("No applied migrations to roll back")

      %{version: version, module: nil} ->
        raise "cannot roll back migration #{version} — its source is missing (applied, " <>
                "source missing). Ask the owner to restore it from the code directory's " <>
                "git history; defining it again would create a new version, not this one."

      %{version: version, module: mod} ->
        Ecto.Migrator.down(Host.Repo, version, mod)
        IO.puts("Rolled back migration #{version} (#{inspect(mod)})")
    end

    :ok
  end

  @doc """
  Prints the migration history: each version with its module and
  whether it is applied (with when) or pending. This is the audit
  trail of every change made to the agent database's tables.
  """
  @spec print_migrations() :: :ok
  def print_migrations do
    IO.puts(render())
    :ok
  end

  defp up!(version, mod) do
    Ecto.Migrator.up(Host.Repo, version, mod)
  rescue
    exception ->
      reraise "migration #{version} (#{inspect(mod)}) failed: #{Exception.message(exception)}",
              __STACKTRACE__
  end

  defp render do
    case Migrations.list() do
      [] ->
        "No migrations yet. Define a module with `use Ecto.Migration`; it becomes " <>
          "migration 1, pending until Host.Migrator.migrate() runs it."

      entries ->
        version_width =
          entries |> Enum.map(&String.length(Integer.to_string(&1.version))) |> Enum.max()

        module_width = entries |> Enum.map(&String.length(module_label(&1))) |> Enum.max()

        lines =
          Enum.map(entries, fn entry ->
            version = entry.version |> Integer.to_string() |> String.pad_leading(version_width)
            module = String.pad_trailing(module_label(entry), module_width)
            "  #{version}  #{module}  #{status(entry)}"
          end)

        Enum.join(["Migrations (Host.Repo):" | lines], "\n")
    end
  end

  defp module_label(%{module: nil}), do: "(missing)"
  defp module_label(%{module: mod}), do: inspect(mod)

  defp status(%{applied_at: nil}), do: "pending"

  defp status(%{applied_at: at, module: nil}),
    do:
      "applied #{Calendar.strftime(at, "%Y-%m-%d %H:%M")} UTC, source missing — " <>
        "ask the owner to restore it; defining it again would create a new version"

  defp status(%{applied_at: at}), do: "applied #{Calendar.strftime(at, "%Y-%m-%d %H:%M")} UTC"
end
