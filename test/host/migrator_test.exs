defmodule Host.MigratorTest do
  # Migrations run through Host.Repo's shared sandbox connection (Ecto
  # applies each one in a task of its own) and the code server touches
  # VM-global state, so nothing here can run async.
  use Beamlet.Case, async: false

  import ExUnit.CaptureIO
  import Ecto.Query

  alias Beamlet.Code
  alias Beamlet.Define
  alias Beamlet.Eval
  alias Beamlet.Migrations

  setup %{token: token, data_dir: data_dir} do
    %{principal: principal(token), code_dir: Path.join(data_dir, "code")}
  end

  defp migration(mod, table, extra \\ "") do
    """
    defmodule #{inspect(mod)} do
      @moduledoc "Creates the #{table} table."
      use Ecto.Migration

      def change do
        create table(:#{table}) do
          add :name, :string
          #{extra}
        end
      end
    end
    """
  end

  defp define!(principal, code, modules, opts \\ []) do
    purge_on_exit(modules)
    Code.define(code, modules, Keyword.get(opts, :replace, false), principal)
  end

  defp applied, do: Migrations.applied_versions()

  defp table_names do
    Host.Repo.all(
      from(t in "sqlite_master", where: t.type == "table", select: t.name, order_by: t.name)
    )
  end

  defp new_migration_names(ns) do
    {Module.concat([ns, CreateLists]), :"#{Macro.underscore(ns)}_lists"}
  end

  defp restart_code_server do
    :ok = Supervisor.terminate_child(Beamlet, Code)
    {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)
  end

  defp stamp(version) do
    {^version, at} =
      Host.Repo.one(
        from(m in "schema_migrations",
          where: m.version == ^version,
          select: {m.version, type(m.inserted_at, :naive_datetime)}
        )
      )

    Calendar.strftime(at, "%Y-%m-%d %H:%M")
  end

  defp printed_migrations, do: capture_io(fn -> assert :ok = Host.Migrator.print_migrations() end)

  describe "define" do
    test "a migration is filed under migrations/ with version 1 and a pending cue", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)

      assert {:ok, summary} = define!(ctx.principal, migration(mod, table), [mod])

      assert summary ==
               "Defined #{inspect(mod)} (new) — migration 1, pending: run Host.Migrator.migrate()"

      file = Path.join(ctx.code_dir, "migrations/0001_#{Macro.underscore(ns)}_create_lists.ex")
      assert File.exists?(file)
      assert Path.wildcard(Path.join(ctx.code_dir, "lib/**/*.ex")) == []
      assert %{^mod => %{source_file: ^file, migration: 1}} = Code.manifest()

      # Nothing is applied by define.
      assert applied() == []
    end

    test "several migrations in one buffer take consecutive versions in buffer order", ctx do
      ns = unique_namespace()
      first = Module.concat([ns, First])
      second = Module.concat([ns, Second])
      helper = Module.concat([ns, Helper])

      code =
        migration(second, "#{Macro.underscore(ns)}_seconds") <>
          """
          defmodule #{inspect(helper)} do
            @moduledoc "Not a migration."

            @doc "Says hi."
            def hi, do: :hi
          end
          """ <>
          migration(first, "#{Macro.underscore(ns)}_firsts")

      assert {:ok, summary} = define!(ctx.principal, code, [second, helper, first])

      assert summary ==
               Enum.join(
                 [
                   "Defined #{inspect(second)} (new) — migration 1, pending: run Host.Migrator.migrate()",
                   "Defined #{inspect(helper)} (new)",
                   "Defined #{inspect(first)} (new) — migration 2, pending: run Host.Migrator.migrate()"
                 ],
                 "\n"
               )

      manifest = Code.manifest()
      assert manifest[second].migration == 1
      assert manifest[first].migration == 2
      assert manifest[helper].migration == nil
      assert manifest[helper].source_file =~ "/lib/"
    end

    test "the next version is one past both the files on disk and the applied history", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)
      later = Module.concat([ns, Later])

      # A file on disk reserves its version whether or not it compiled.
      File.write!(
        Path.join(ctx.code_dir, "migrations/0003_hand_written.ex"),
        "this does not compile\n"
      )

      assert {:ok, summary} = define!(ctx.principal, migration(mod, table), [mod])
      assert summary =~ "migration 4, pending"

      # Applied history counts too: apply 4, remove its file behind the
      # server's back, and the next define still lands past it.
      capture_io(fn -> Host.Migrator.migrate() end)
      assert applied() == [4]
      File.rm!(Code.manifest()[mod].source_file)

      assert {:ok, summary} = define!(ctx.principal, migration(later, "#{table}_later"), [later])
      assert summary =~ "migration 5, pending"
    end

    test "a replace keeps a pending migration's version and file", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)

      assert {:ok, _summary} = define!(ctx.principal, migration(mod, table), [mod])
      file = Code.manifest()[mod].source_file

      assert {:ok, summary} =
               define!(ctx.principal, migration(mod, table, "add :done, :boolean"), [mod],
                 replace: true
               )

      assert summary =~ "(replaced) — migration 1, pending"
      assert Code.manifest()[mod].source_file == file
      assert File.read!(file) =~ "add :done, :boolean"
    end

    test "a replace that changes a module's kind moves its file between the roots", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)

      plain = """
      defmodule #{inspect(mod)} do
        @moduledoc "Now a plain module."

        @doc "Says hi."
        def hi, do: :hi
      end
      """

      assert {:ok, _summary} = define!(ctx.principal, migration(mod, table), [mod])
      migration_file = Code.manifest()[mod].source_file

      assert {:ok, "Defined " <> _rest = summary} =
               define!(ctx.principal, plain, [mod], replace: true)

      refute summary =~ "migration"
      refute File.exists?(migration_file)
      assert %{migration: nil, source_file: lib_file} = Code.manifest()[mod]
      assert lib_file =~ "/lib/"

      # Its old number is free again: neither on disk nor applied.
      assert {:ok, summary} = define!(ctx.principal, migration(mod, table), [mod], replace: true)
      assert summary =~ "migration 1, pending"
      refute File.exists?(lib_file)
      assert File.exists?(migration_file)
    end

    test "the define tool returns the pending cue", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)
      purge_on_exit([mod])

      assert {:ok, summary} = Define.run(migration(mod, table), ctx.principal)
      assert summary =~ "migration 1, pending: run Host.Migrator.migrate()"
    end

    test "the git history records the migration file", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)

      assert {:ok, _summary} = define!(ctx.principal, migration(mod, table), [mod])

      {files, 0} = System.cmd("git", ["ls-files"], cd: ctx.code_dir, stderr_to_stdout: true)
      assert files =~ "migrations/0001_#{Macro.underscore(ns)}_create_lists.ex"

      {message, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: ctx.code_dir)
      assert String.trim(message) == "define: #{inspect(mod)} (new)"
    end
  end

  describe "migrate/0 and rollback/0" do
    test "applies pending migrations in order, printing each, and the tables are queryable",
         ctx do
      ns = unique_namespace()
      one = Module.concat([ns, One])
      two = Module.concat([ns, Two])
      prefix = Macro.underscore(ns)

      assert {:ok, _} = define!(ctx.principal, migration(one, "#{prefix}_ones"), [one])
      assert {:ok, _} = define!(ctx.principal, migration(two, "#{prefix}_twos"), [two])

      assert capture_io(fn -> assert :ok = Host.Migrator.migrate() end) ==
               "Applied migration 1 (#{inspect(one)})\nApplied migration 2 (#{inspect(two)})\n"

      assert applied() == [1, 2]
      assert "#{prefix}_ones" in table_names()
      assert "#{prefix}_twos" in table_names()

      Host.Repo.insert_all("#{prefix}_ones", [%{name: "milk"}])
      assert Host.Repo.all(from(r in "#{prefix}_ones", select: r.name)) == ["milk"]

      assert capture_io(fn -> Host.Migrator.migrate() end) == "No pending migrations\n"

      assert printed_migrations() ==
               Enum.join(
                 [
                   "Migrations (Host.Repo):",
                   "  1  #{inspect(one)}  applied #{stamp(1)} UTC",
                   "  2  #{inspect(two)}  applied #{stamp(2)} UTC\n"
                 ],
                 "\n"
               )
    end

    test "a mid-batch failure leaves the earlier ones applied and names the one that failed",
         ctx do
      ns = unique_namespace()
      good = Module.concat([ns, Good])
      bad = Module.concat([ns, Bad])
      table = "#{Macro.underscore(ns)}_things"

      assert {:ok, _} = define!(ctx.principal, migration(good, table), [good])
      # The same table again: SQLite refuses the second create.
      assert {:ok, _} = define!(ctx.principal, migration(bad, table), [bad])

      output =
        capture_io(fn ->
          error = assert_raise RuntimeError, fn -> Host.Migrator.migrate() end
          assert error.message =~ "migration 2 (#{inspect(bad)}) failed: "
          assert error.message =~ "already exists"
        end)

      assert output == "Applied migration 1 (#{inspect(good)})\n"
      assert applied() == [1]
      assert printed_migrations() =~ ~r/^  2  #{Regex.escape(inspect(bad))}\s+pending$/m
    end

    test "rollback pops the top, replace is then allowed, and migrate re-applies", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)

      assert {:ok, _} = define!(ctx.principal, migration(mod, table), [mod])
      capture_io(fn -> Host.Migrator.migrate() end)

      assert capture_io(fn -> assert :ok = Host.Migrator.rollback() end) ==
               "Rolled back migration 1 (#{inspect(mod)})\n"

      assert applied() == []
      refute table in table_names()
      assert printed_migrations() =~ "  1  #{inspect(mod)}  pending"

      assert {:ok, _} =
               define!(ctx.principal, migration(mod, table, "add :done, :boolean"), [mod],
                 replace: true
               )

      capture_io(fn -> Host.Migrator.migrate() end)
      assert applied() == [1]
      assert Host.Repo.all(from(r in "#{table}", select: r.done)) == []

      assert capture_io(fn -> Host.Migrator.rollback() end) ==
               "Rolled back migration 1 (#{inspect(mod)})\n"

      assert capture_io(fn -> Host.Migrator.rollback() end) ==
               "No applied migrations to roll back\n"
    end

    test "an applied migration refuses replace and remove until rolled back", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)

      assert {:ok, _} = define!(ctx.principal, migration(mod, table), [mod])
      capture_io(fn -> Host.Migrator.migrate() end)

      assert {:error, message} =
               define!(ctx.principal, migration(mod, table), [mod], replace: true)

      assert message ==
               "cannot replace #{inspect(mod)} — migration 1 is applied. Roll it back first " <>
                 "with Host.Migrator.rollback(), then replace it."

      assert {:error, message} = Code.remove([mod], ctx.principal)

      assert message ==
               "cannot remove #{inspect(mod)} — migration 1 is applied. Roll it back first " <>
                 "with Host.Migrator.rollback(), then remove it."

      capture_io(fn -> Host.Migrator.rollback() end)
      assert :ok = Code.remove([mod], ctx.principal)
      assert Migrations.list() == []
      assert printed_migrations() =~ "No migrations yet."
    end

    test "an applied migration whose file is gone is an orphan: marked, blocks rollback", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)
      next = Module.concat([ns, Next])

      assert {:ok, _} = define!(ctx.principal, migration(mod, table), [mod])
      capture_io(fn -> Host.Migrator.migrate() end)
      File.rm!(Code.manifest()[mod].source_file)

      # A restart of the code server on the same dir is the reboot.
      :code.purge(mod)
      :code.delete(mod)
      ExUnit.CaptureLog.capture_log(fn -> restart_code_server() end)
      refute Map.has_key?(Code.manifest(), mod)

      assert printed_migrations() ==
               "Migrations (Host.Repo):\n  1  (missing)  applied #{stamp(1)} UTC, source missing — " <>
                 "ask the owner to restore it; defining it again would create a new version\n"

      error = assert_raise RuntimeError, fn -> Host.Migrator.rollback() end
      assert error.message =~ "cannot roll back migration 1 — its source is missing"

      # migrate is unaffected: an orphan is always below the pending set.
      assert {:ok, summary} = define!(ctx.principal, migration(next, "#{table}_next"), [next])
      assert summary =~ "migration 2, pending"

      assert capture_io(fn -> Host.Migrator.migrate() end) ==
               "Applied migration 2 (#{inspect(next)})\n"

      assert applied() == [1, 2]
    end
  end

  describe "through eval" do
    test "agent code migrates and reads the history", ctx do
      ns = unique_namespace()
      {mod, table} = new_migration_names(ns)

      assert {:ok, _} = define!(ctx.principal, migration(mod, table), [mod])

      assert {:ok, "Applied migration 1 (#{inspect(mod)})\n\n=> :ok"} ==
               Eval.run("Host.Migrator.migrate()", ctx.principal)

      assert {:ok, output} = Eval.run("Host.Migrator.print_migrations()", ctx.principal)
      assert output =~ "  1  #{inspect(mod)}  applied"
    end
  end
end
