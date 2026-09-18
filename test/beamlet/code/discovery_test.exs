defmodule Beamlet.Code.DiscoveryTest do
  # Loaded modules and the compiler tracer option are VM-global.
  use Beamlet.Case, async: false

  alias Beamlet.Code
  alias Beamlet.Code.Discovery
  alias Beamlet.Define
  alias Beamlet.Policy

  setup %{token: token} do
    %{principal: principal(token)}
  end

  # The effective policy as Host.Code builds it: the principal's with
  # the defined modules granted by existence.
  defp effective(policy \\ Policy.default()), do: Policy.grant(policy, Code.defined())

  defp define_greeter!(principal) do
    ns = unique_namespace()
    mod = Module.concat([ns, Greeter])
    purge_on_exit([mod])

    {:ok, _summary} =
      Define.run(
        """
        defmodule #{ns}.Greeter do
          @moduledoc \"\"\"
          Greets people warmly.

          Detail that belongs to a second paragraph.
          \"\"\"

          @doc "Greets by name."
          def hello(name), do: "hello \#{name}"

          @doc "Waves goodbye, once or several times."
          def bye(name), do: "bye \#{name}"
          def bye(name, times), do: String.duplicate("bye ", times) <> name
        end
        """,
        principal
      )

    {ns, mod}
  end

  defp restart_code_server do
    :ok = Supervisor.terminate_child(Beamlet, Code)
    {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)
  end

  defp quarantine!(data_dir) do
    ns = unique_namespace()
    mod = Module.concat([ns, Bad])
    purge_on_exit([mod])
    file = Path.join(data_dir, "code/lib/bad.ex")

    File.write!(file, """
    defmodule #{ns}.Bad do
      @moduledoc "Broken."
      def broken, do: undefined_local()
    end
    """)

    ExUnit.CaptureLog.capture_log(fn -> quiet(fn -> restart_code_server() end) end)
    {ns, mod, file}
  end

  describe "list/1" do
    test "shows defined, host, framework and library modules, never the platform", ctx do
      {ns, _mod} = define_greeter!(ctx.principal)

      assert {:ok, text} = Discovery.list(effective())

      assert text =~ ~r/^  Host\.Code — Discover what is on your beamlet/m

      assert text =~
               ~r/^  Host\.PubSub — Publish\/subscribe on your beamlet's shared message bus\.$/m

      assert text =~ "  #{ns}.Greeter — Greets people warmly."
      refute text =~ "second paragraph"
      assert text =~ ~r/\bPhoenix\.Controller, /
      assert text =~ ~r/\bPhoenix\.LiveView,/
      assert text =~ ~r/\bPlug\.Conn$/m
      refute text =~ ~r/^  Phoenix\.LiveView — /m
      refute text =~ "Phoenix.Flash (:phoenix)"
      assert text =~ ~r/^  Req \(:req\) — Req is a batteries-included HTTP client/m
      assert text =~ ~r/^  Jason \(:jason\) — A blazing fast JSON parser/m
      refute text =~ ~r/^  Req\.Steps\b/m
      refute text =~ ~r/^  Enum\b/m
      refute text =~ ~r/^  Kernel\b/m
      refute text =~ ~r/^  Macro\b/m
    end

    test "the data surface: Host.Repo once, Ecto as framework names, no exceptions" do
      assert {:ok, text} = Discovery.list(effective())

      assert text =~ ~r/^  Host\.Repo — The agent database/m
      assert text =~ ~r/^  Ecto, Ecto\.Changeset, Ecto\.Enum, Ecto\.Migration, /m
      assert text =~ ~r/\bEcto\.Query\.API, /
      refute text =~ ~r/^  Ecto\.Changeset — /m
      refute text =~ "Ecto.NoResultsError"
      refute text =~ "Ecto.Repo"
      refute text =~ ~r/^    insert\(/m
    end

    test "sections come in order: defined, host, framework, libraries" do
      assert {:ok, text} = Discovery.list(effective())

      headings = [
        "Defined modules (define):",
        "Host modules (your beamlet's stdlib):",
        "Framework modules (what you write pages and data against; print_docs for any):",
        "Libraries (every module of each package is available):"
      ]

      positions = Enum.map(headings, fn heading -> :binary.match(text, heading) |> elem(0) end)
      assert positions == Enum.sort(positions)
    end

    test "a module granted from another package renders as its own line" do
      policy = effective()
      policy = %{policy | grants: Map.put(policy.grants, Ecto.Adapters.SQLite3, :all)}

      assert {:ok, text} = Discovery.list(policy)

      assert text =~ ~r/^  Ecto\.Adapters\.SQLite3 \(:ecto_sqlite3\) — /m
    end

    test "a migration is not listed; the footer points at its listing", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, CreateLists])
      purge_on_exit([mod])

      {:ok, _summary} =
        Define.run(
          """
          defmodule #{ns}.CreateLists do
            @moduledoc "Creates the lists table."
            use Ecto.Migration

            def change do
              create table(:#{Macro.underscore(ns)}_lists) do
                add :name, :string
              end
            end
          end
          """,
          ctx.principal
        )

      assert {:ok, text} = Discovery.list(effective())
      refute text =~ "CreateLists"
      assert text =~ "Defined modules (define):\n  (none yet"

      assert String.ends_with?(
               text,
               "Host.Code.print_docs(Module) for documentation; " <>
                 "Host.Router.print_routes() for the routes; " <>
                 "Host.Migrator.print_migrations() for the migrations."
             )
    end

    test "a quarantined module is listed with its error", ctx do
      {ns, _mod, _file} = quarantine!(ctx.data_dir)

      assert {:ok, text} = Discovery.list(effective())

      assert text =~
               ~r/^  #{ns}\.Bad — quarantined: .*undefined_local.* \(define it again with replace: true, or Host\.Code\.remove it\)$/m
    end

    test "renders placeholders for empty sections" do
      policy = %{Policy.default() | grants: %{Host.Code => :all}}

      assert {:ok, text} = Discovery.list(policy)

      assert text =~
               "Defined modules (define):\n  (none yet — build something durable with define)"

      assert text =~
               "Framework modules (what you write pages and data against; print_docs for any):\n  (none)"

      assert text =~ "Libraries (every module of each package is available):\n  (none)"
    end
  end

  describe "doc/2 at module level" do
    test "renders a defined module from its beam", ctx do
      {ns, mod} = define_greeter!(ctx.principal)

      assert {:ok, text} = Discovery.doc(effective(), mod)

      assert text =~ "# #{ns}.Greeter"
      assert text =~ "Greets people warmly."
      assert text =~ "second paragraph"
      assert text =~ ~r/^  bye\(name\) — Waves goodbye/m
      assert text =~ ~r/^  hello\(name\) — Greets by name\./m
      refute text =~ "not shown"
    end

    test "serves a granted platform module by name" do
      assert {:ok, text} = Discovery.doc(effective(), Enum)

      assert text =~ "# Enum"
      assert text =~ "## Functions"
      assert text =~ ~r/^  map\(enumerable, fun\) — /m
    end

    test "filters the index to the granted functions" do
      assert {:ok, text} = Discovery.doc(effective(), IO)

      assert text =~ ~r/^  puts\(/m
      assert text =~ ~r/^  inspect\(/m
      refute text =~ ~r/^  write\(/m
      assert text =~ ~r/^\(\d+ functions not shown — not permitted by your policy\)$/m
    end

    test "a denied module gets the scanner's copy with its hint" do
      assert {:error, message} = Discovery.doc(effective(), Phoenix.PubSub)

      assert message ==
               "Phoenix.PubSub is not permitted by your policy — " <>
                 "publish/subscribe goes through Host.PubSub"
    end

    test "Host.Repo joins Ecto.Repo's callback docs onto its generated functions" do
      assert {:ok, text} = Discovery.doc(effective(), Host.Repo)

      assert text =~ "# Host.Repo"
      assert text =~ "The agent database"
      assert text =~ ~r/^  insert\(struct, opts \\\\ \[\]\) — Inserts a struct/m
      assert text =~ ~r/^  all\(queryable, opts \\\\ \[\]\) — Fetches all entries/m
      assert text =~ ~r/^  to_sql\(operation, queryable.* — /m
      assert text =~ ~r/^  child_spec\(opts\)$/m
      assert text =~ ~r/^  query\(sql, params \\\\ \[\], opts \\\\ \[\]\) — /m
      refute text =~ ~r/^  put_dynamic_repo\(/m
      assert text =~ ~r/^\(\d+ functions not shown — not permitted by your policy\)$/m
    end

    test "an unknown module is not a policy matter" do
      assert {:error, message} = Discovery.doc(effective(), No.Such.Module)
      assert message =~ "nothing named No.Such.Module exists on your beamlet"
    end

    test "a module without a docs chunk reports no documentation" do
      mod = Module.concat([unique_namespace(), Bare])
      purge_on_exit([mod])
      Module.create(mod, quote(do: def(go, do: :ok)), Macro.Env.location(__ENV__))

      assert {:error, message} = Discovery.doc(effective() |> Policy.grant([mod]), mod)
      assert message =~ "no documentation is available for #{inspect(mod)}"
    end
  end

  describe "doc/4 at function level" do
    test "renders every arity of a function", ctx do
      {ns, mod} = define_greeter!(ctx.principal)

      assert {:ok, text} = Discovery.doc(effective(), mod, :bye)

      assert text =~ "# #{ns}.Greeter.bye(name)"
      assert text =~ "Waves goodbye, once or several times."
      assert text =~ "# #{ns}.Greeter.bye(name, times)"
      assert text =~ "(no documentation)"
    end

    test "renders one arity when given", ctx do
      {ns, mod} = define_greeter!(ctx.principal)

      assert {:ok, text} = Discovery.doc(effective(), mod, :bye, 2)

      assert text =~ "# #{ns}.Greeter.bye(name, times)"
      refute text =~ "Waves goodbye"
    end

    test "an arity collapsed into default arguments still matches" do
      assert {:ok, text} = Discovery.doc(effective(), IO, :puts, 1)
      assert text =~ "# IO.puts("
    end

    test "a missing function names the module's index", ctx do
      {_ns, mod} = define_greeter!(ctx.principal)

      assert {:error, message} = Discovery.doc(effective(), mod, :bye, 9)

      assert message =~ "has no public function or macro named bye/9"
      assert message =~ "Host.Code.print_docs(#{inspect(mod)}) lists what it has"
    end

    test "a denied function gets the policy copy with its hint, never no-docs" do
      assert {:error, message} = Discovery.doc(effective(), Kernel, :apply, 2)
      assert message == "Kernel.apply/2 is not permitted by your policy"

      assert {:error, message} = Discovery.doc(effective(), Kernel, :spawn)

      assert message ==
               "Kernel.spawn is not permitted by your policy — " <>
                 "process primitives are withheld as a family; there is no sibling to reach for"
    end

    test "a Host.Repo function renders Ecto's full callback doc" do
      assert {:ok, text} = Discovery.doc(effective(), Host.Repo, :insert)

      assert text =~ "# Host.Repo.insert(struct, opts \\\\ [])"
      assert text =~ "Inserts a struct defined via `Ecto.Schema` or a changeset."
      assert text =~ "## Options"

      assert {:error, message} = Discovery.doc(effective(), Host.Repo, :put_dynamic_repo, 1)
      assert message == "Host.Repo.put_dynamic_repo/1 is not permitted by your policy"
    end
  end

  describe "source/2" do
    test "returns a defined module's source", ctx do
      {ns, mod} = define_greeter!(ctx.principal)

      assert {:ok, source} = Discovery.source(effective(), mod)

      assert source =~ "defmodule #{ns}.Greeter do"
      assert source =~ "def bye(name, times), do:"
    end

    test "returns a quarantined module's source", ctx do
      {ns, mod, _file} = quarantine!(ctx.data_dir)

      assert {:ok, source} = Discovery.source(effective(), mod)
      assert source =~ "defmodule #{ns}.Bad do"
    end

    test "beamlet modules get a teaching error pointing at docs" do
      assert {:error, message} = Discovery.source(effective(), Enum)

      assert message =~ "defined modules only"
      assert message =~ "Host.Code.print_docs(Enum)"
    end

    test "an unknown module is named as such" do
      assert {:error, message} = Discovery.source(effective(), No.Such.Module)
      assert message =~ "nothing named No.Such.Module exists on your beamlet"
    end
  end
end
