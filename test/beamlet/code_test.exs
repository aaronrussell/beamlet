defmodule Beamlet.CodeTest do
  use Beamlet.Case

  alias Beamlet.Code

  setup %{token: token, data_dir: data_dir} do
    %{principal: principal(token), code_dir: Path.join(data_dir, "code")}
  end

  # One entry per source; `replace:` applies to every entry of the
  # call and `timeout:` rides the options.
  defp define(sources, principal, opts \\ []) do
    entries = sources |> List.wrap() |> Enum.map(&entry(&1, Keyword.take(opts, [:replace])))
    Code.define(entries, principal, Keyword.take(opts, [:timeout]))
  end

  defp restart_code_server do
    :ok = Supervisor.terminate_child(Beamlet, Code)
    {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)
  end

  defp unload(modules) do
    Enum.each(modules, fn mod ->
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end)
  end

  describe "define/3" do
    test "a new module lands on disk, loads, and keeps its docs", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Shopping])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Shopping do
        @moduledoc "Tracks the shopping list."

        @doc "Adds an item."
        def add(list, item), do: [item | list]
      end
      """

      assert {:ok, summary} = define(code, ctx.principal)
      assert summary == "Defined #{ns}.Shopping (new)"

      assert apply(mod, :add, [[], :milk]) == [:milk]

      source_file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/shopping.ex")
      assert File.read!(source_file) == code

      beam_file = Path.join(ctx.code_dir, "ebin/Elixir.#{ns}.Shopping.beam")
      assert File.exists?(beam_file)
      assert {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Elixir.Code.fetch_docs(beam_file)
      assert doc =~ "Tracks the shopping list."

      assert Code.defined() == [mod]

      assert Code.manifest() == %{
               mod => %{source_file: source_file, beam_file: beam_file, migration: nil}
             }

      refute File.exists?(Path.join(ctx.code_dir, ".staging"))
    end

    test "several entries land one file per module", ctx do
      ns = unique_namespace()
      a = Module.concat([ns, A])
      b = Module.concat([ns, B])
      purge_on_exit([a, b])

      sources = [
        """
        # A comes first.
        defmodule #{ns}.A do
          @moduledoc "A."
          def one, do: 1
        end
        """,
        """
        # B builds on A.
        defmodule #{ns}.B do
          @moduledoc "B."
          def two, do: #{ns}.A.one() + 1
        end
        """
      ]

      assert {:ok, summary} = define(sources, ctx.principal)
      assert summary == "Defined #{ns}.A (new)\nDefined #{ns}.B (new)"
      assert apply(b, :two, []) == 2

      dir = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}")
      assert File.read!(Path.join(dir, "a.ex")) == hd(sources)
      assert File.read!(Path.join(dir, "b.ex")) == List.last(sources)
    end

    test "an empty call is rejected", ctx do
      assert {:error, message} = Code.define([], ctx.principal)
      assert message == "define names no modules — pass one entry per module"
    end

    test "redefining a defined module teaches replace:", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Thing])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Thing do
        @moduledoc "Does the thing."
        def go, do: :v1
      end
      """

      assert {:ok, _summary} = define(code, ctx.principal)
      assert {:error, message} = define(code, ctx.principal)
      assert message =~ "#{ns}.Thing already exists"
      assert message =~ "\"Does the thing.\""
      assert message =~ "set replace: true on its entry"
    end

    test "the already-exists error quotes a wrapped moduledoc's whole first paragraph", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Wrapped])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Wrapped do
        @moduledoc "Keeps the shopping list in order, sorted by aisle\\nand then by name.\\n\\nThe second paragraph stays out."
        def go, do: :v1
      end
      """

      assert {:ok, _summary} = define(code, ctx.principal)
      assert {:error, message} = define(code, ctx.principal)

      assert message =~
               "already exists — \"Keeps the shopping list in order, sorted by aisle and then " <>
                 "by name.\""
    end

    test "a module the beamlet already has is rejected with no flag", ctx do
      code = """
      defmodule Enum do
        def map(x), do: x
      end
      """

      assert {:error, message} = define(code, ctx.principal)
      assert message =~ "Enum is an existing module on your beamlet"
      assert Enum.map([1], & &1) == [1]
    end

    test "reserved prefixes are rejected", ctx do
      assert {:error, message} = define("defmodule Host.Sneaky do\nend", ctx.principal)
      assert message =~ "Beamlet.* and Host.* are reserved"

      assert {:error, message} = define("defmodule Beamlet.Sneaky do\nend", ctx.principal)
      assert message =~ "reserved"
    end

    test "a stray replace: true on a new module is harmless permission", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Fresh])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Fresh do
        @moduledoc "Fresh."
      end
      """

      assert {:ok, summary} = define(code, ctx.principal, replace: true)
      assert summary == "Defined #{ns}.Fresh (new)"
    end

    test "a name that maps to a defined module's file is refused, that file untouched", ctx do
      ns = unique_namespace()
      held = Module.concat([ns, HTTPClient])
      purge_on_exit([held, Module.concat([ns, HttpClient])])

      code = """
      defmodule #{ns}.HTTPClient do
        @moduledoc "Fetches."
      end
      """

      assert {:ok, _summary} = define(code, ctx.principal)

      assert {:error, message} =
               define("defmodule #{ns}.HttpClient do\nend", ctx.principal, replace: true)

      assert message ==
               "#{ns}.HttpClient would be stored at lib/#{Macro.underscore(ns)}/http_client.ex, " <>
                 "which already holds #{ns}.HTTPClient. Choose another name for " <>
                 "#{ns}.HttpClient: a module's file is named for its underscored name, so " <>
                 "names that differ only in capitalisation share one."

      file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/http_client.ex")
      assert File.read!(file) == code
      assert Code.defined() == [held]
      refute Elixir.Code.ensure_loaded?(Module.concat([ns, HttpClient]))
    end

    test "a name that maps to a quarantined file is refused", ctx do
      ns = unique_namespace()
      held = Module.concat([ns, HTTPClient])
      purge_on_exit([held, Module.concat([ns, HttpClient])])

      file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/http_client.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule #{ns}.HTTPClient do\n  def go(x), do: missing(x)\nend\n")

      ExUnit.CaptureLog.capture_log(fn -> quiet(fn -> restart_code_server() end) end)
      assert [%{modules: [^held]}] = Code.quarantined()

      assert {:error, message} = define("defmodule #{ns}.HttpClient do\nend", ctx.principal)
      assert message =~ "which already holds #{ns}.HTTPClient"
      assert File.exists?(file)
    end

    test "two names in one call that map to one file are refused", ctx do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, HTTPClient]), Module.concat([ns, HttpClient])])

      assert {:error, message} =
               define(
                 ["defmodule #{ns}.HTTPClient do\nend", "defmodule #{ns}.HttpClient do\nend"],
                 ctx.principal
               )

      assert message =~
               "#{ns}.HTTPClient and #{ns}.HttpClient would both be stored at " <>
                 "lib/#{Macro.underscore(ns)}/http_client.ex. Choose another name for one of them"

      assert Code.defined() == []
    end

    test "replace recompiles the dependent and reports it", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Item])
      basket = Module.concat([ns, Basket])
      purge_on_exit([item, basket])

      sources = [
        """
        defmodule #{ns}.Item do
          @moduledoc "An item."
          defstruct [:name]
        end
        """,
        """
        defmodule #{ns}.Basket do
          @moduledoc "A basket."
          def sample, do: %#{ns}.Item{name: "milk"}
        end
        """
      ]

      assert {:ok, _summary} = define(sources, ctx.principal)

      replacement = """
      defmodule #{ns}.Item do
        @moduledoc "An item, now with a count."
        defstruct [:name, count: 1]
      end
      """

      assert {:ok, summary} = define(replacement, ctx.principal, replace: true)

      assert summary ==
               "Defined #{ns}.Item (replaced)\n  - no function changes\n" <>
                 "Recompiled dependents: #{ns}.Basket"

      assert apply(basket, :sample, []) == struct(item, name: "milk", count: 1)
    end

    test "a replace that breaks its dependent changes nothing", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Item])
      basket = Module.concat([ns, Basket])
      purge_on_exit([item, basket])

      sources = [
        """
        defmodule #{ns}.Item do
          @moduledoc "An item."
          defstruct [:name]
        end
        """,
        """
        defmodule #{ns}.Basket do
          @moduledoc "A basket."
          def sample, do: %#{ns}.Item{name: "milk"}
        end
        """
      ]

      assert {:ok, _summary} = define(sources, ctx.principal)
      item_file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/item.ex")
      item_source = File.read!(item_file)

      breaking = """
      defmodule #{ns}.Item do
        @moduledoc "An item without a name."
        defstruct [:label]
      end
      """

      assert {:error, message} =
               quiet(fn -> define(breaking, ctx.principal, replace: true) end)

      assert message =~ "broke its dependent #{ns}.Basket"
      assert message =~ "lib/#{Macro.underscore(ns)}/basket.ex:3: "
      assert message =~ "\n    def sample, do: %#{ns}.Item{name: \"milk\"}\n"
      assert message =~ "Nothing was changed."
      assert message =~ "Update #{ns}.Basket in the same call"

      assert apply(basket, :sample, []) == struct(item, name: "milk")
      assert File.read!(item_file) == item_source
      refute File.exists?(Path.join(ctx.code_dir, ".staging"))
    end

    test "the compile timeout leaves the world untouched", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Slow])

      code = """
      defmodule #{ns}.Slow do
        @moduledoc "Slow to compile."
        Enum.each(1..5_000_000_000, fn _ -> :ok end)
      end
      """

      assert {:error, message} = define(code, ctx.principal, timeout: 50)
      assert message =~ "define timed out after 50ms — nothing was changed"
      refute loaded?(mod)
      assert Path.wildcard(Path.join(ctx.code_dir, "lib/**/*.ex")) == []
      assert Code.defined() == []
    end

    test "a cancelled define is aborted and rolled back", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Slow])
      Process.register(self(), :define_probe)

      code = """
      defmodule #{ns}.Slow do
        @moduledoc "Slow to compile."
        send(:define_probe, {:compiling, self()})
        Enum.each(1..5_000_000_000, fn _ -> :ok end)
      end
      """

      caller = spawn(fn -> define(code, ctx.principal) end)

      assert_receive {:compiling, compiler}, 5_000
      compiler_ref = Process.monitor(compiler)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^compiler_ref, :process, ^compiler, :killed}, 5_000
      :sys.get_state(Code)
      refute loaded?(mod)
      assert Path.wildcard(Path.join(ctx.code_dir, "lib/**/*.ex")) == []
      refute File.exists?(Path.join(ctx.code_dir, ".staging"))
      assert Code.defined() == []
    end
  end

  describe "compile errors" do
    test "locate by the module's path and quote the line, staging path never shown", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Bad])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Bad do
        @moduledoc "Bad."
        def broken, do: undefined_local()
      end
      """

      assert {:error, message} = quiet(fn -> define(code, ctx.principal) end)
      path = "lib/#{Macro.underscore(ns)}/bad.ex"

      assert message =~ ~r/\A#{Regex.escape(path)}:3: undefined function undefined_local\/0/
      assert message =~ "\n    def broken, do: undefined_local()"
      refute message =~ "cannot compile module"
      refute message =~ ".staging"
      refute loaded?(mod)
      refute File.exists?(Path.join(ctx.code_dir, ".staging"))
    end

    test "name the failing entry of a call, not its neighbour", ctx do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, Fine]), Module.concat([ns, Bad])])

      sources = [
        "defmodule #{ns}.Fine do\n  @moduledoc \"Fine.\"\nend\n",
        "defmodule #{ns}.Bad do\n  @moduledoc \"Bad.\"\n  def broken, do: undefined_local()\nend\n"
      ]

      assert {:error, message} = quiet(fn -> define(sources, ctx.principal) end)

      assert message =~
               "lib/#{Macro.underscore(ns)}/bad.ex:3: undefined function undefined_local/0"

      refute message =~ "fine.ex"
      assert Code.defined() == []
    end

    test "an exception raised in the module body locates by its frame", ctx do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, Thing])])

      code = """
      defmodule #{ns}.Thing do
        @moduledoc "Thing."
        use Ecto.Schema

        schema "things" do
          field :name, :no_such_type
        end
      end
      """

      assert {:error, message} = quiet(fn -> define(code, ctx.principal) end)
      path = "lib/#{Macro.underscore(ns)}/thing.ex"

      assert message =~
               ~r/\A#{Regex.escape(path)}:6: \*\* \(ArgumentError\) unknown type :no_such_type for field :name\n/

      assert message =~ "Ecto.Schema.__field__/4"
      assert message =~ "\n    #{path}:6: (module)\n"
      assert message =~ "field :name, :no_such_type"
      refute message =~ "elixir_compiler"
      refute message =~ ".staging"
    end

    test "a defined module's frames in the trace read as locators", ctx do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, Boom]), Module.concat([ns, Caller])])

      boom = """
      defmodule #{ns}.Boom do
        @moduledoc "Boom."
        def boom!, do: raise(ArgumentError, "boom")
      end
      """

      caller = """
      defmodule #{ns}.Caller do
        @moduledoc "Caller."
        @value #{ns}.Boom.boom!()
        def value, do: @value
      end
      """

      assert {:ok, _summary} = define(boom, ctx.principal)
      assert {:error, message} = quiet(fn -> define(caller, ctx.principal) end)
      dir = "lib/#{Macro.underscore(ns)}"

      assert message =~ ~r/\A#{Regex.escape(dir)}\/caller.ex:3: \*\* \(ArgumentError\) boom\n/
      assert message =~ "#{dir}/boom.ex:3: #{ns}.Boom.boom!/0"
      refute message =~ ".staging"
    end
  end

  describe "migrations" do
    test "a module that compiles as a migration without the use line is refused", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Sly])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Sly do
        @moduledoc "Claims to be a migration."
        def __migration__, do: []
      end
      """

      assert {:error, message} = define(code, ctx.principal)

      assert message ==
               "#{ns}.Sly compiled as a migration without saying so — write " <>
                 "`use Ecto.Migration` directly in the module, so it is filed under migrations/"

      refute loaded?(mod)
      assert Code.defined() == []
      assert Path.wildcard(Path.join(ctx.code_dir, "{lib,migrations}/**/*.ex")) == []
    end
  end

  describe "boot" do
    test "compiles the code dir and quarantines what fails", ctx do
      ns = unique_namespace()
      good = Module.concat([ns, Good])
      bad = Module.concat([ns, Bad])
      dep = Module.concat([ns, Dep])
      purge_on_exit([good, bad, dep])

      lib = Path.join(ctx.code_dir, "lib")

      File.write!(Path.join(lib, "good.ex"), """
      defmodule #{ns}.Good do
        @moduledoc "Good."
        def ok, do: :good
      end
      """)

      File.write!(Path.join(lib, "bad.ex"), """
      defmodule #{ns}.Bad do
        @moduledoc "Broken."
        def broken, do: undefined_local()
      end
      """)

      File.write!(Path.join(lib, "dep.ex"), """
      defmodule #{ns}.Dep do
        @moduledoc "Depends on Bad."
        def make, do: %#{ns}.Bad{}
      end
      """)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          quiet(fn -> restart_code_server() end)

          assert apply(good, :ok, []) == :good
          assert Code.defined() == [good]

          quarantined = Code.quarantined()

          assert quarantined |> Enum.flat_map(& &1.modules) |> Enum.sort() ==
                   Enum.sort([bad, dep])

          assert [%{file: bad_file, error: error}, %{file: dep_file}] = quarantined
          assert bad_file == Path.join(lib, "bad.ex")
          assert dep_file == Path.join(lib, "dep.ex")
          assert error =~ "undefined_local"

          assert Map.keys(Code.manifest()) == [good]
          refute loaded?(bad)
        end)

      assert log =~ "code boot: quarantined lib/bad.ex"
      assert log =~ "code boot: quarantined lib/dep.ex"
    end

    test "a file that does not parse is quarantined under its defmodule name", ctx do
      ns = unique_namespace()
      torn = Module.concat([ns, Torn])
      purge_on_exit([torn])
      file = Path.join(ctx.code_dir, "lib/torn.ex")

      File.write!(file, """
      defmodule #{ns}.Torn do
        @moduledoc "Torn."
        def x do
      end
      """)

      ExUnit.CaptureLog.capture_log(fn -> quiet(fn -> restart_code_server() end) end)

      assert [%{file: ^file, modules: [^torn], error: error}] = Code.quarantined()
      assert error =~ "TokenMissingError"
    end

    test "quarantines a file whose function clauses are scattered", ctx do
      ns = unique_namespace()
      good = Module.concat([ns, Good])
      scattered = Module.concat([ns, Scattered])
      purge_on_exit([good, scattered])

      lib = Path.join(ctx.code_dir, "lib")

      File.write!(Path.join(lib, "good.ex"), """
      defmodule #{ns}.Good do
        @moduledoc "Good."
        def ok, do: :good
      end
      """)

      File.write!(Path.join(lib, "scattered.ex"), """
      defmodule #{ns}.Scattered do
        @moduledoc "Hand-edited into scattered clauses."
        def size(:small), do: 1
        def name, do: "x"
        def size(:large), do: 3
      end
      """)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          quiet(fn -> restart_code_server() end)

          assert apply(good, :ok, []) == :good
          assert Code.defined() == [good]

          assert [%{file: file, modules: [^scattered], error: error}] = Code.quarantined()
          assert file == Path.join(lib, "scattered.ex")

          assert error ==
                   "def size/1 (lib/scattered.ex:5) is separated from its earlier clause " <>
                     "(lib/scattered.ex:3) by other definitions — group the clauses of a " <>
                     "function together"

          refute loaded?(scattered)
        end)

      assert log =~ "code boot: quarantined lib/scattered.ex: def size/1 (lib/scattered.ex:5)"
    end

    test "carries no policy gate: the code dir is operator-mediated", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, HandEdited])
      purge_on_exit([mod])

      File.write!(Path.join(ctx.code_dir, "lib/hand_edited.ex"), """
      defmodule #{ns}.HandEdited do
        @moduledoc "Hand-edited by the operator; calls a denied module and defines a macro."
        def read(path), do: File.read!(path)

        defmacro double(x) do
          quote do: unquote(x) * 2
        end
      end
      """)

      ExUnit.CaptureLog.capture_log(fn -> restart_code_server() end)
      assert Code.quarantined() == []
      assert Code.defined() == [mod]

      assert %{^mod => %{source_file: source_file}} = Code.manifest()
      assert source_file == Path.join(ctx.code_dir, "lib/hand_edited.ex")
    end

    test "defined modules survive a restart", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Item])
      basket = Module.concat([ns, Basket])
      purge_on_exit([item, basket])

      sources = [
        """
        defmodule #{ns}.Item do
          @moduledoc "An item."
          defstruct [:name]
        end
        """,
        """
        defmodule #{ns}.Basket do
          @moduledoc "A basket."
          def sample, do: %#{ns}.Item{name: "milk"}
        end
        """
      ]

      assert {:ok, _summary} = define(sources, ctx.principal)

      # The closest in-VM analogue of a restart: drop the loaded
      # modules so only the code dir survives.
      :ok = Supervisor.terminate_child(Beamlet, Code)
      unload([item, basket])
      {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)

      assert apply(basket, :sample, []) == struct(item, name: "milk")
      assert Code.defined() == Enum.sort([item, basket])
      assert Code.quarantined() == []

      assert {:error, message} = Code.remove([item], ctx.principal)
      assert message =~ "#{ns}.Basket depends on it at compile time"
    end
  end

  describe "generated modules" do
    # An inline embed is compiled into a module of its own, Order.Item,
    # that no top-level defmodule declares.
    defp order(ns, embed \\ "Item", extra \\ "") do
      """
      defmodule #{ns}.Order do
        @moduledoc "An order."
        use Ecto.Schema

        embedded_schema do
          embeds_one :line, #{embed} do
            field :name, :string
          end
        end

        @doc "A line named `name`."
        def line(name), do: %#{ns}.Order.#{embed}{name: name}
      #{extra}end
      """
    end

    test "an embed is not defined, before or after a restart", ctx do
      ns = unique_namespace()
      parent = Module.concat([ns, Order])
      item = Module.concat([ns, Order, Item])
      purge_on_exit([parent, item])

      assert define(order(ns), ctx.principal) == {:ok, "Defined #{ns}.Order (new)"}
      assert apply(parent, :line, ["tea"]) == struct(item, name: "tea")
      assert Code.defined() == [parent]

      quiet(fn -> restart_code_server() end)
      assert Code.defined() == [parent]
      assert Map.keys(Code.manifest()) == [parent]
      assert apply(parent, :line, ["tea"]) == struct(item, name: "tea")
    end

    test "removing an embed is refused, naming its owner, and its source survives", ctx do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, Order]), Module.concat([ns, Order, Item])])
      assert {:ok, _summary} = define(order(ns), ctx.principal)
      quiet(fn -> restart_code_server() end)

      assert Code.remove([Module.concat([ns, Order, Item])], ctx.principal) ==
               {:error,
                "#{ns}.Order.Item is generated by the source of #{ns}.Order " <>
                  "(lib/#{Macro.underscore(ns)}/order.ex), an embedded schema or the like — " <>
                  "remove #{ns}.Order, and it goes too."}

      assert File.exists?(Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/order.ex"))
    end

    test "an embed's name cannot be defined as a module", ctx do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, Order]), Module.concat([ns, Order, Item])])
      assert {:ok, _summary} = define(order(ns), ctx.principal)

      assert {:error, message} = define("defmodule #{ns}.Order.Item do\nend", ctx.principal)
      assert message =~ "#{ns}.Order.Item is generated by the source of #{ns}.Order"
      assert message =~ "choose another name."
    end

    test "removing the owner takes its embeds", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Order, Item])
      purge_on_exit([Module.concat([ns, Order]), item])
      assert {:ok, _summary} = define(order(ns), ctx.principal)

      assert :ok = Code.remove([Module.concat([ns, Order])], ctx.principal)
      refute Elixir.Code.ensure_loaded?(item)
      refute File.exists?(Path.join(ctx.code_dir, "ebin/#{item}.beam"))
    end

    test "a replace that renames an embed unloads the old one", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Order, Item])
      entry = Module.concat([ns, Order, Entry])
      purge_on_exit([Module.concat([ns, Order]), item, entry])
      assert {:ok, _summary} = define(order(ns), ctx.principal)

      assert {:ok, _summary} = define(order(ns, "Entry"), ctx.principal, replace: true)
      assert Elixir.Code.ensure_loaded?(entry)
      refute Elixir.Code.ensure_loaded?(item)
      refute File.exists?(Path.join(ctx.code_dir, "ebin/#{item}.beam"))

      assert {:error, message} = define("defmodule #{ns}.Order.Entry do\nend", ctx.principal)
      assert message =~ "is generated by the source of #{ns}.Order"
    end

    test "a failed replace puts the old embed back and drops the new one", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Order, Item])
      entry = Module.concat([ns, Order, Entry])
      purge_on_exit([Module.concat([ns, Order]), item, entry])
      assert {:ok, _summary} = define(order(ns), ctx.principal)

      broken = order(ns, "Entry", "  @doc \"Broken.\"\n  def broken, do: missing()\n")
      assert {:error, message} = quiet(fn -> define(broken, ctx.principal, replace: true) end)
      assert message =~ "undefined function missing/0"

      assert Elixir.Code.ensure_loaded?(item)
      refute Elixir.Code.ensure_loaded?(entry)
    end

    test "an embed's calls are its owner's", ctx do
      ns = unique_namespace()
      kinds = Module.concat([ns, Kinds])
      purge_on_exit([kinds, Module.concat([ns, Order]), Module.concat([ns, Order, Item])])

      assert {:ok, _summary} =
               define(
                 """
                 defmodule #{ns}.Kinds do
                   @moduledoc "Kinds."
                   @doc "All of them."
                   def all, do: [:tea, :cake]
                 end
                 """,
                 ctx.principal
               )

      assert {:ok, _summary} =
               define(
                 """
                 defmodule #{ns}.Order do
                   @moduledoc "An order."
                   use Ecto.Schema

                   embedded_schema do
                     embeds_one :line, Item do
                       field :kind, Ecto.Enum, values: #{ns}.Kinds.all()
                     end
                   end
                 end
                 """,
                 ctx.principal
               )

      assert {:error, message} = Code.remove([kinds], ctx.principal)
      assert message =~ "cannot remove #{ns}.Kinds — #{ns}.Order calls all/0"
    end

    defp basket(ns, body) do
      """
      defmodule #{ns}.Basket do
        @moduledoc "A basket."
        @doc "A sample."
        def sample, do: #{body}
      end
      """
    end

    test "a struct of an embed is a compile-time edge to its owner", ctx do
      ns = unique_namespace()
      order = Module.concat([ns, Order])
      purge_on_exit([order, Module.concat([ns, Order, Item]), Module.concat([ns, Basket])])
      assert {:ok, _summary} = define(order(ns), ctx.principal)
      assert {:ok, _summary} = define(basket(ns, ~s(%#{ns}.Order.Item{name: "x"})), ctx.principal)

      renamed = String.replace(order(ns), "field :name", "field :title")
      renamed = String.replace(renamed, "{name: name}", "{title: name}")

      assert {:error, message} = quiet(fn -> define(renamed, ctx.principal, replace: true) end)
      assert message =~ "replacing #{ns}.Order broke its dependent #{ns}.Basket"

      assert {:error, message} = Code.remove([order], ctx.principal)
      assert message =~ "cannot remove #{ns}.Order — #{ns}.Basket depends on it at compile time"
    end

    test "an edge to an embed defined in the same call holds, and survives a restart", ctx do
      ns = unique_namespace()
      order = Module.concat([ns, Order])
      purge_on_exit([order, Module.concat([ns, Order, Item]), Module.concat([ns, Basket])])

      # The attribute waits for the embed to load, so the struct after
      # it is traced against a loaded module no one has named.
      basket = """
      defmodule #{ns}.Basket do
        @moduledoc "A basket."
        @fields #{ns}.Order.Item.__schema__(:fields)

        @doc "A sample."
        def sample, do: {@fields, %#{ns}.Order.Item{name: "x"}}
      end
      """

      assert {:ok, _summary} = define([order(ns), basket], ctx.principal)

      refusal =
        "cannot remove #{ns}.Order — #{ns}.Basket calls #{ns}.Order.Item.__schema__/1 " <>
          "and depends on it at compile time."

      assert {:error, message} = Code.remove([order], ctx.principal)
      assert message =~ refusal

      quiet(fn -> restart_code_server() end)
      assert {:error, message} = Code.remove([order], ctx.principal)
      assert message =~ refusal
    end

    test "a call to an embed is a call to its owner's module", ctx do
      ns = unique_namespace()
      order = Module.concat([ns, Order])
      purge_on_exit([order, Module.concat([ns, Order, Item]), Module.concat([ns, Basket])])
      assert {:ok, _summary} = define(order(ns), ctx.principal)

      assert {:ok, _summary} =
               define(basket(ns, "#{ns}.Order.Item.__schema__(:fields)"), ctx.principal)

      assert {:error, message} = Code.remove([order], ctx.principal)

      assert message =~
               "cannot remove #{ns}.Order — #{ns}.Basket calls #{ns}.Order.Item.__schema__/1"

      assert {:ok, summary} = define(order(ns), ctx.principal, replace: true)
      assert summary =~ "Note: called at runtime by #{ns}.Basket (#{ns}.Order.Item.__schema__/1)"

      dropped = order(ns, "Entry")
      assert {:error, message} = define(dropped, ctx.principal, replace: true)

      assert message =~
               "replacing #{ns}.Order broke its caller #{ns}.Basket — #{ns}.Basket calls " <>
                 "#{ns}.Order.Item.__schema__/1, which the replacement no longer defines"
    end
  end

  describe "runtime call records" do
    test "plain calls and captures are recorded with name and arity", ctx do
      ns = unique_namespace()
      util = Module.concat([ns, Util])
      user = Module.concat([ns, User])
      purge_on_exit([util, user])

      sources = [
        """
        defmodule #{ns}.Util do
          @moduledoc "Util."
          def a, do: :a
          def b(_x), do: :b
        end
        """,
        """
        defmodule #{ns}.User do
          @moduledoc "User."
          def go, do: #{ns}.Util.a()
          def ref, do: &#{ns}.Util.b/1
        end
        """
      ]

      assert {:ok, _summary} = define(sources, ctx.principal)
      assert {:error, message} = Code.remove([util], ctx.principal)
      assert message =~ "cannot remove #{ns}.Util — #{ns}.User calls a/0, b/1."
    end

    test "the call records rebuild at boot", ctx do
      ns = unique_namespace()
      store = Module.concat([ns, Store])
      client = Module.concat([ns, Client])
      purge_on_exit([store, client])

      sources = [
        """
        defmodule #{ns}.Store do
          @moduledoc "Store."
          def get(key), do: {:ok, key}
        end
        """,
        """
        defmodule #{ns}.Client do
          @moduledoc "Client."
          def fetch(key), do: #{ns}.Store.get(key)
        end
        """
      ]

      assert {:ok, _summary} = define(sources, ctx.principal)

      :ok = Supervisor.terminate_child(Beamlet, Code)
      unload([store, client])
      {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)

      assert {:error, message} = Code.remove([store], ctx.principal)
      assert message =~ "#{ns}.Client calls get/1."
    end
  end

  describe "replace and runtime callers" do
    defp store_and_client(principal, ns) do
      sources = [
        """
        defmodule #{ns}.Store do
          @moduledoc "Store."
          def get(key), do: {:ok, key}
          def put(key), do: {:ok, key}
        end
        """,
        """
        defmodule #{ns}.Client do
          @moduledoc "Client."
          def fetch(key), do: #{ns}.Store.get(key)
        end
        """
      ]

      assert {:ok, _summary} = define(sources, principal)
    end

    test "dropping a function a surviving caller uses is refused, world untouched", ctx do
      ns = unique_namespace()
      store = Module.concat([ns, Store])
      client = Module.concat([ns, Client])
      purge_on_exit([store, client])
      store_and_client(ctx.principal, ns)
      store_file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/store.ex")
      store_source = File.read!(store_file)

      breaking = """
      defmodule #{ns}.Store do
        @moduledoc "Store, without get."
        def put(key), do: {:ok, key}
      end
      """

      assert {:error, message} = define(breaking, ctx.principal, replace: true)

      assert message ==
               "replacing #{ns}.Store broke its caller #{ns}.Client — #{ns}.Client calls " <>
                 "#{ns}.Store.get/1, which the replacement no longer defines. Nothing was " <>
                 "changed. Update #{ns}.Client in the same call, or keep #{ns}.Store.get/1."

      assert apply(store, :get, [:milk]) == {:ok, :milk}
      assert apply(client, :fetch, [:milk]) == {:ok, :milk}
      assert File.read!(store_file) == store_source
    end

    test "updating the caller in the same call lets the drop through", ctx do
      ns = unique_namespace()
      store = Module.concat([ns, Store])
      client = Module.concat([ns, Client])
      purge_on_exit([store, client])
      store_and_client(ctx.principal, ns)

      fixed = [
        """
        defmodule #{ns}.Store do
          @moduledoc "Store, without get."
          def put(key), do: {:ok, key}
        end
        """,
        """
        defmodule #{ns}.Client do
          @moduledoc "Client."
          def fetch(key), do: #{ns}.Store.put(key)
        end
        """
      ]

      assert {:ok, _summary} = define(fixed, ctx.principal, replace: true)
      assert apply(client, :fetch, [:milk]) == {:ok, :milk}
      assert {:error, message} = Code.remove([store], ctx.principal)
      assert message =~ "#{ns}.Client calls put/1."
    end

    test "a compatible replace names its surviving runtime callers", ctx do
      ns = unique_namespace()
      store = Module.concat([ns, Store])
      client = Module.concat([ns, Client])
      purge_on_exit([store, client])
      store_and_client(ctx.principal, ns)

      compatible = """
      defmodule #{ns}.Store do
        @moduledoc "Store, evolved."
        def get(key), do: {:ok, {key, :fresh}}
        def put(key), do: {:ok, key}
      end
      """

      assert {:ok, summary} = define(compatible, ctx.principal, replace: true)

      assert summary ==
               "Defined #{ns}.Store (replaced)\n  - changed get/1\n" <>
                 "Note: called at runtime by #{ns}.Client (get/1)"
    end
  end

  describe "the replace summary" do
    @old_list """
    defmodule NS.List do
      @moduledoc "A list."

      @doc "Load."
      def load(id), do: id

      @doc "List."
      def list, do: []

      @doc "Total."
      def total(x), do: x

      @doc "Render."
      def render(x), do: x
    end
    """

    @new_list """
    defmodule NS.List do
      @moduledoc "A list."

      @doc "Total."
      def total(x) when is_list(x), do: Enum.sum(x)
      def total(x), do: x

      @doc "Rendered."
      def render(x), do: x

      @doc "Remove."
      def remove(a, b), do: {a, b}
    end
    """

    test "names the functions removed, changed and added", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, List])
      purge_on_exit([mod])

      assert {:ok, _summary} = define(String.replace(@old_list, "NS", ns), ctx.principal)

      assert {:ok, summary} =
               define(String.replace(@new_list, "NS", ns), ctx.principal, replace: true)

      assert summary ==
               Enum.join(
                 [
                   "Defined #{ns}.List (replaced)",
                   "  - removed load/1, list/0",
                   "  - changed total/1 (1 to 2 clauses), render/1",
                   "  - new remove/2"
                 ],
                 "\n"
               )
    end

    test "the same source again is unchanged", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, List])
      purge_on_exit([mod])
      source = String.replace(@old_list, "NS", ns)

      assert {:ok, _summary} = define(source, ctx.principal)
      assert {:ok, summary} = define(source, ctx.principal, replace: true)
      assert summary == "Defined #{ns}.List (replaced)\n  - unchanged"
    end

    test "a replaced quarantined module is compared with its quarantined source", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, List])
      purge_on_exit([mod])

      File.write!(Path.join(ctx.code_dir, "lib/list.ex"), """
      defmodule #{ns}.List do
        @moduledoc "A list, broken by hand."
        def load(id), do: undefined_local(id)
        def total(x), do: x
      end
      """)

      ExUnit.CaptureLog.capture_log(fn -> quiet(fn -> restart_code_server() end) end)
      assert [%{modules: [^mod]}] = Code.quarantined()

      assert {:ok, summary} =
               define(String.replace(@new_list, "NS", ns), ctx.principal, replace: true)

      assert summary ==
               Enum.join(
                 [
                   "Defined #{ns}.List (replaced)",
                   "  - removed load/1",
                   "  - changed total/1 (1 to 2 clauses)",
                   "  - new render/1, remove/2"
                 ],
                 "\n"
               )

      assert Code.quarantined() == []
      refute File.exists?(Path.join(ctx.code_dir, "lib/list.ex"))
    end

    test "a quarantined source that does not parse has nothing to compare", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, List])
      purge_on_exit([mod])

      File.write!(Path.join(ctx.code_dir, "lib/list.ex"), """
      defmodule #{ns}.List do
        @moduledoc "Torn."
        def load(id) do
      end
      """)

      ExUnit.CaptureLog.capture_log(fn -> quiet(fn -> restart_code_server() end) end)
      assert [%{modules: [^mod]}] = Code.quarantined()

      assert {:ok, summary} =
               define(String.replace(@new_list, "NS", ns), ctx.principal, replace: true)

      assert summary ==
               "Defined #{ns}.List (replaced)\n" <>
                 "  - previous source did not parse, so nothing to compare"

      assert Code.quarantined() == []
    end
  end

  describe "remove/2" do
    test "removes a module: unloaded, files deleted, state dropped", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Toss])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Toss do
        @moduledoc "Throwaway."
        def hi, do: :hi
      end
      """

      assert {:ok, _summary} = define(code, ctx.principal)
      source_file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/toss.ex")
      beam_file = Path.join(ctx.code_dir, "ebin/Elixir.#{ns}.Toss.beam")
      assert File.exists?(source_file)
      assert File.exists?(beam_file)

      assert :ok = Code.remove([mod], ctx.principal)

      refute loaded?(mod)
      refute File.exists?(source_file)
      refute File.exists?(beam_file)
      assert Code.defined() == []
      assert Code.manifest() == %{}
      assert define(code, ctx.principal) == {:ok, "Defined #{ns}.Toss (new)"}
    end

    test "a remove whose caller died while it was queued never runs", ctx do
      ns = unique_namespace()
      keep = Module.concat([ns, Keep])
      purge_on_exit([keep, Module.concat([ns, Slow])])
      Process.register(self(), :define_probe)

      assert {:ok, _summary} =
               define("defmodule #{ns}.Keep do\n  @moduledoc \"Keep.\"\nend", ctx.principal)

      slow = """
      defmodule #{ns}.Slow do
        @moduledoc "Compiles when let go."
        send(:define_probe, {:compiling, self()})
        receive do: (:go -> :ok)
      end
      """

      test = self()
      spawn(fn -> send(test, {:defined, define(slow, ctx.principal)}) end)
      assert_receive {:compiling, compiler}, 5_000

      # Tracing the server's receives shows the remove queued behind
      # the define before its caller is killed.
      server = Process.whereis(Code)
      :erlang.trace(server, true, [:receive])
      remover = spawn(fn -> Code.remove([keep], ctx.principal) end)

      assert_receive {:trace, ^server, :receive, {:"$gen_call", _from, {:remove, [^keep], _}}},
                     5_000

      :erlang.trace(server, false, [:receive])
      remover_ref = Process.monitor(remover)
      Process.exit(remover, :kill)
      assert_receive {:DOWN, ^remover_ref, :process, ^remover, :killed}

      send(compiler, :go)
      assert_receive {:defined, {:ok, _summary}}, 5_000
      :sys.get_state(Code)

      assert keep in Code.defined()
      assert loaded?(keep)
      assert File.exists?(Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/keep.ex"))
    end

    test "a removal survives a restart", ctx do
      ns = unique_namespace()
      keep = Module.concat([ns, Keep])
      toss = Module.concat([ns, Toss])
      purge_on_exit([keep, toss])

      sources = [
        """
        defmodule #{ns}.Keep do
          @moduledoc "Keep."
          def hi, do: :hi
        end
        """,
        """
        defmodule #{ns}.Toss do
          @moduledoc "Throwaway."
          def hi, do: :hi
        end
        """
      ]

      assert {:ok, _summary} = define(sources, ctx.principal)
      assert :ok = Code.remove([toss], ctx.principal)

      :ok = Supervisor.terminate_child(Beamlet, Code)
      unload([keep, toss])
      {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)

      assert Code.defined() == [keep]
      refute loaded?(toss)
    end

    test "a runtime caller refuses the removal, naming what it calls", ctx do
      ns = unique_namespace()
      store = Module.concat([ns, Store])
      client = Module.concat([ns, Client])
      purge_on_exit([store, client])

      sources = [
        """
        defmodule #{ns}.Store do
          @moduledoc "Store."
          def get(key), do: {:ok, key}
        end
        """,
        """
        defmodule #{ns}.Client do
          @moduledoc "Client."
          def fetch(key), do: #{ns}.Store.get(key)
        end
        """
      ]

      assert {:ok, _summary} = define(sources, ctx.principal)
      assert {:error, message} = Code.remove([store], ctx.principal)

      assert message ==
               "cannot remove #{ns}.Store — #{ns}.Client calls get/1.\n" <>
                 "Remove or rework the dependents first, or remove them together in one " <>
                 "remove call."

      assert Code.defined() == Enum.sort([store, client])
      assert apply(client, :fetch, [:milk]) == {:ok, :milk}
    end

    test "a compile-time dependent refuses the removal", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Item])
      basket = Module.concat([ns, Basket])
      purge_on_exit([item, basket])

      sources = [
        """
        defmodule #{ns}.Item do
          @moduledoc "An item."
          defstruct [:name]
        end
        """,
        """
        defmodule #{ns}.Basket do
          @moduledoc "A basket."
          def sample, do: %#{ns}.Item{name: "milk"}
        end
        """
      ]

      assert {:ok, _summary} = define(sources, ctx.principal)
      assert {:error, message} = Code.remove([item], ctx.principal)
      assert message =~ "cannot remove #{ns}.Item — #{ns}.Basket depends on it at compile time."
    end

    test "mutual callers remove only as one set", ctx do
      ns = unique_namespace()
      ping = Module.concat([ns, Ping])
      pong = Module.concat([ns, Pong])
      purge_on_exit([ping, pong])

      sources = [
        """
        defmodule #{ns}.Ping do
          @moduledoc "Ping."
          def ping(0), do: :done
          def ping(n), do: #{ns}.Pong.pong(n - 1)
        end
        """,
        """
        defmodule #{ns}.Pong do
          @moduledoc "Pong."
          def pong(0), do: :done
          def pong(n), do: #{ns}.Ping.ping(n - 1)
        end
        """
      ]

      assert {:ok, _summary} = define(sources, ctx.principal)

      assert {:error, message} = Code.remove([ping], ctx.principal)
      assert message =~ "cannot remove #{ns}.Ping — #{ns}.Pong calls ping/1."
      assert Code.defined() == Enum.sort([ping, pong])

      assert :ok = Code.remove([ping, pong], ctx.principal)
      assert Code.defined() == []
      refute loaded?(ping)
      refute loaded?(pong)
    end

    test "beamlet modules and unknown names get teaching errors", ctx do
      ns = unique_namespace()
      nope = Module.concat([ns, Nope])

      assert {:error, message} = Code.remove([Enum], ctx.principal)

      assert message ==
               "Host.Code.remove removes defined modules only — Enum is part of your beamlet."

      assert {:error, message} = Code.remove([nope], ctx.principal)

      assert message ==
               "#{ns}.Nope is not a defined module — Host.Code.print_modules() shows what is."

      assert {:error, message} = Code.remove([], ctx.principal)
      assert message == "remove names no modules — pass a module or a list of modules"
    end

    test "a quarantined module is removable, taking its file and entry", ctx do
      ns = unique_namespace()
      bad = Module.concat([ns, Bad])
      purge_on_exit([bad])

      bad_file = Path.join(ctx.code_dir, "lib/bad.ex")

      File.write!(bad_file, """
      defmodule #{ns}.Bad do
        @moduledoc "Broken."
        def broken, do: undefined_local()
      end
      """)

      ExUnit.CaptureLog.capture_log(fn ->
        quiet(fn -> restart_code_server() end)
        assert [%{modules: [^bad]}] = Code.quarantined()

        assert :ok = Code.remove([bad], ctx.principal)

        refute File.exists?(bad_file)
        assert Code.quarantined() == []
      end)
    end
  end

  describe "a patch" do
    @list """
    defmodule NS.List do
      @moduledoc "A list."

      @doc "Total."
      def total(x), do: x
    end
    """

    defp patch_entry(source, hash, label \\ "patch 1 (NS.List, select total/1)") do
      Map.merge(entry(source, replace: true), %{hash: hash, label: label})
    end

    defp sha(source), do: :crypto.hash(:sha256, source)

    test "lands when the hash matches the file, summarised as Patched", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, List])
      purge_on_exit([mod])
      old = String.replace(@list, "NS", ns)
      new = String.replace(old, "def total(x), do: x", "def total(x), do: x * 2")

      assert {:ok, _summary} = define(old, ctx.principal)

      assert {:ok, summary} =
               Code.define([patch_entry(new, sha(old))], ctx.principal, verb: :patch)

      assert summary == "Patched #{inspect(mod)}\n  - changed total/1"
      assert apply(mod, :total, [2]) == 4
    end

    test "a stale hash is refused with nothing changed, and the current one lands", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, List])
      purge_on_exit([mod])
      old = String.replace(@list, "NS", ns)
      new = String.replace(old, "def total(x), do: x", "def total(x), do: x * 2")
      file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/list.ex")

      assert {:ok, _summary} = define(old, ctx.principal)

      assert Code.define([patch_entry(new, sha("something else"))], ctx.principal, verb: :patch) ==
               {:error,
                "#{inspect(mod)} changed while you were patching it — read it again and " <>
                  "patch the current source. Nothing was changed."}

      assert File.read!(file) == old
      assert apply(mod, :total, [2]) == 2

      assert {:ok, _summary} =
               Code.define([patch_entry(new, sha(File.read!(file)))], ctx.principal, verb: :patch)

      assert apply(mod, :total, [2]) == 4
    end

    test "a module removed in the window is refused with its own wording", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, List])
      purge_on_exit([mod])
      old = String.replace(@list, "NS", ns)

      assert {:ok, _summary} = define(old, ctx.principal)
      assert :ok = Code.remove([mod], ctx.principal)

      assert Code.define([patch_entry(old, sha(old))], ctx.principal, verb: :patch) ==
               {:error,
                "#{inspect(mod)} was removed while you were patching it — nothing was " <>
                  "changed. Host.Code.print_modules() shows what is defined."}

      refute loaded?(mod)
      assert Code.defined() == []
    end

    test "a compile error in a patched module carries its label", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, List])
      purge_on_exit([mod])
      old = String.replace(@list, "NS", ns)
      new = String.replace(old, "def total(x), do: x", "def total(x), do: y")

      assert {:ok, _summary} = define(old, ctx.principal)

      assert {:error, message} =
               quiet(fn ->
                 Code.define([patch_entry(new, sha(old))], ctx.principal,
                   verb: :patch,
                   context: 1
                 )
               end)

      assert message =~
               "patch 1 (NS.List, select total/1): lib/#{Macro.underscore(ns)}/list.ex:5: " <>
                 "undefined variable \"y\""

      assert message =~ "    4 |   @doc \"Total.\"\n    5 |   def total(x), do: y\n    6 | end"
    end
  end
end
