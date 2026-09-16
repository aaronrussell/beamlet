defmodule Beamlet.CodeTest do
  # Loaded modules and the compiler tracer option are VM-global.
  use Beamlet.Case, async: false

  alias Beamlet.Code

  setup %{token: token, data_dir: data_dir} do
    %{principal: principal(token), code_dir: Path.join(data_dir, "code")}
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

  describe "define/5" do
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

      assert {:ok, summary} = Code.define(code, [mod], false, ctx.principal)
      assert summary == "Defined #{ns}.Shopping (new)"

      assert apply(mod, :add, [[], :milk]) == [:milk]

      source_file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/shopping.ex")
      assert File.read!(source_file) =~ "Tracks the shopping list."

      beam_file = Path.join(ctx.code_dir, "ebin/Elixir.#{ns}.Shopping.beam")
      assert File.exists?(beam_file)
      assert {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Elixir.Code.fetch_docs(beam_file)
      assert doc =~ "Tracks the shopping list."

      assert Code.defined() == [mod]
    end

    test "a multi-module buffer splits into one file per module", ctx do
      ns = unique_namespace()
      a = Module.concat([ns, A])
      b = Module.concat([ns, B])
      purge_on_exit([a, b])

      code = """
      # A comes first.
      defmodule #{ns}.A do
        @moduledoc "A."
        def one, do: 1
      end

      # B builds on A.
      defmodule #{ns}.B do
        @moduledoc "B."
        def two, do: #{ns}.A.one() + 1
      end
      """

      assert {:ok, summary} = Code.define(code, [a, b], false, ctx.principal)
      assert summary == "Defined #{ns}.A (new)\nDefined #{ns}.B (new)"
      assert apply(b, :two, []) == 2

      dir = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}")
      a_source = File.read!(Path.join(dir, "a.ex"))
      b_source = File.read!(Path.join(dir, "b.ex"))
      assert a_source =~ "# A comes first."
      assert a_source =~ "defmodule #{ns}.A do"
      refute a_source =~ "defmodule #{ns}.B do"
      assert b_source =~ "# B builds on A."
      assert b_source =~ "defmodule #{ns}.B do"
    end

    test "an empty buffer is rejected", ctx do
      assert {:error, message} = Code.define("", [], false, ctx.principal)
      assert message =~ "defines no modules"
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

      assert {:ok, _summary} = Code.define(code, [mod], false, ctx.principal)
      assert {:error, message} = Code.define(code, [mod], false, ctx.principal)
      assert message =~ "#{ns}.Thing already exists"
      assert message =~ "\"Does the thing.\""
      assert message =~ "call define again with replace: true"
    end

    test "a module the beamlet already has is rejected with no flag", ctx do
      code = """
      defmodule Enum do
        def map(x), do: x
      end
      """

      assert {:error, message} = Code.define(code, [Enum], false, ctx.principal)
      assert message =~ "Enum is an existing module on your beamlet"
      assert Enum.map([1], & &1) == [1]
    end

    test "reserved prefixes are rejected", ctx do
      code = "defmodule Host.Sneaky do\nend"
      assert {:error, message} = Code.define(code, [Host.Sneaky], false, ctx.principal)
      assert message =~ "Beamlet.* and Host.* are reserved"

      code = "defmodule Beamlet.Sneaky do\nend"
      assert {:error, message} = Code.define(code, [Beamlet.Sneaky], false, ctx.principal)
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

      assert {:ok, summary} = Code.define(code, [mod], true, ctx.principal)
      assert summary == "Defined #{ns}.Fresh (new)"
    end

    test "replace recompiles the dependent and reports it", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Item])
      basket = Module.concat([ns, Basket])
      purge_on_exit([item, basket])

      code = """
      defmodule #{ns}.Item do
        @moduledoc "An item."
        defstruct [:name]
      end

      defmodule #{ns}.Basket do
        @moduledoc "A basket."
        def sample, do: %#{ns}.Item{name: "milk"}
      end
      """

      assert {:ok, _summary} = Code.define(code, [item, basket], false, ctx.principal)
      assert Code.deps()[basket] == [item]

      replacement = """
      defmodule #{ns}.Item do
        @moduledoc "An item, now with a count."
        defstruct [:name, count: 1]
      end
      """

      assert {:ok, summary} = Code.define(replacement, [item], true, ctx.principal)
      assert summary == "Defined #{ns}.Item (replaced)\nRecompiled dependents: #{ns}.Basket"
      assert apply(basket, :sample, []) == struct(item, name: "milk", count: 1)
    end

    test "a replace that breaks its dependent changes nothing", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Item])
      basket = Module.concat([ns, Basket])
      purge_on_exit([item, basket])

      code = """
      defmodule #{ns}.Item do
        @moduledoc "An item."
        defstruct [:name]
      end

      defmodule #{ns}.Basket do
        @moduledoc "A basket."
        def sample, do: %#{ns}.Item{name: "milk"}
      end
      """

      assert {:ok, _summary} = Code.define(code, [item, basket], false, ctx.principal)
      item_file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/item.ex")
      item_source = File.read!(item_file)

      breaking = """
      defmodule #{ns}.Item do
        @moduledoc "An item without a name."
        defstruct [:label]
      end
      """

      assert {:error, message} =
               quiet(fn -> Code.define(breaking, [item], true, ctx.principal) end)

      assert message =~ "broke its dependent #{ns}.Basket"
      assert message =~ "Nothing was changed."

      assert apply(basket, :sample, []) == struct(item, name: "milk")
      assert File.read!(item_file) == item_source
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

      assert {:error, message} = Code.define(code, [mod], false, ctx.principal, timeout: 50)
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

      caller = spawn(fn -> Code.define(code, [mod], false, ctx.principal) end)

      assert_receive {:compiling, compiler}, 5_000
      compiler_ref = Process.monitor(compiler)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^compiler_ref, :process, ^compiler, :killed}, 5_000
      :sys.get_state(Code)
      refute loaded?(mod)
      assert Path.wildcard(Path.join(ctx.code_dir, "lib/**/*.ex")) == []
      assert Path.wildcard(Path.join(ctx.code_dir, ".staging/*")) == []
      assert Code.defined() == []
    end

    test "raising exceptions compiles and runs", ctx do
      ns = unique_namespace()
      error_mod = Module.concat([ns, EmptyListError])
      list_mod = Module.concat([ns, StrictList])
      purge_on_exit([error_mod, list_mod])

      code = """
      defmodule #{ns}.EmptyListError do
        @moduledoc "Raised on an empty list."
        defexception message: "the list is empty"
      end

      defmodule #{ns}.StrictList do
        @moduledoc "A list that refuses to be empty."

        def first!([]), do: raise(#{ns}.EmptyListError)
        def first!([head | _]), do: head

        def check!(nil), do: raise(ArgumentError, "no list given")
        def check!(_list), do: raise("just checking")
      end
      """

      assert {:ok, _summary} = Code.define(code, [error_mod, list_mod], false, ctx.principal)

      assert apply(list_mod, :first!, [[1, 2]]) == 1
      assert_raise error_mod, fn -> apply(list_mod, :first!, [[]]) end
      assert_raise ArgumentError, "no list given", fn -> apply(list_mod, :check!, [nil]) end
      assert_raise RuntimeError, "just checking", fn -> apply(list_mod, :check!, [[1]]) end
    end

    test "typespecs compile", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Typed])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Typed do
        @moduledoc "Carries typespecs."

        defstruct [:name, :count]

        @type t :: %__MODULE__{name: String.t(), count: non_neg_integer()}

        @spec bump(t()) :: t()
        def bump(typed), do: %{typed | count: typed.count + 1}
      end
      """

      assert {:ok, _summary} = Code.define(code, [mod], false, ctx.principal)
      assert apply(mod, :bump, [struct(mod, name: "x", count: 1)]).count == 2
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

          refute loaded?(bad)
        end)

      assert log =~ "code boot: quarantined lib/bad.ex"
      assert log =~ "code boot: quarantined lib/dep.ex"
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

      restart_code_server()
      assert Code.quarantined() == []
      assert Code.defined() == [mod]
    end

    test "defined modules survive a restart", ctx do
      ns = unique_namespace()
      item = Module.concat([ns, Item])
      basket = Module.concat([ns, Basket])
      purge_on_exit([item, basket])

      code = """
      defmodule #{ns}.Item do
        @moduledoc "An item."
        defstruct [:name]
      end

      defmodule #{ns}.Basket do
        @moduledoc "A basket."
        def sample, do: %#{ns}.Item{name: "milk"}
      end
      """

      assert {:ok, _summary} = Code.define(code, [item, basket], false, ctx.principal)

      # The closest in-VM analogue of a restart: drop the loaded
      # modules so only the code dir survives.
      :ok = Supervisor.terminate_child(Beamlet, Code)
      unload([item, basket])
      {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)

      assert apply(basket, :sample, []) == struct(item, name: "milk")
      assert Code.defined() == Enum.sort([item, basket])
      assert Code.deps()[basket] == [item]
      assert Code.quarantined() == []
    end
  end

  describe "runtime call records" do
    test "plain calls and captures land in the calls map with name and arity", ctx do
      ns = unique_namespace()
      util = Module.concat([ns, Util])
      user = Module.concat([ns, User])
      purge_on_exit([util, user])

      code = """
      defmodule #{ns}.Util do
        @moduledoc "Util."
        def a, do: :a
        def b(_x), do: :b
      end

      defmodule #{ns}.User do
        @moduledoc "User."
        def go, do: #{ns}.Util.a()
        def ref, do: &#{ns}.Util.b/1
      end
      """

      assert {:ok, _summary} = Code.define(code, [util, user], false, ctx.principal)
      assert Code.calls()[user] == %{util => [a: 0, b: 1]}
      assert Code.calls()[util] == %{}
    end

    test "the calls map rebuilds at boot", ctx do
      ns = unique_namespace()
      store = Module.concat([ns, Store])
      client = Module.concat([ns, Client])
      purge_on_exit([store, client])

      code = """
      defmodule #{ns}.Store do
        @moduledoc "Store."
        def get(key), do: {:ok, key}
      end

      defmodule #{ns}.Client do
        @moduledoc "Client."
        def fetch(key), do: #{ns}.Store.get(key)
      end
      """

      assert {:ok, _summary} = Code.define(code, [store, client], false, ctx.principal)

      :ok = Supervisor.terminate_child(Beamlet, Code)
      unload([store, client])
      {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)

      assert Code.calls()[client] == %{store => [get: 1]}
    end
  end

  describe "replace and runtime callers" do
    defp store_and_client(principal, ns, store, client) do
      code = """
      defmodule #{ns}.Store do
        @moduledoc "Store."
        def get(key), do: {:ok, key}
        def put(key), do: {:ok, key}
      end

      defmodule #{ns}.Client do
        @moduledoc "Client."
        def fetch(key), do: #{ns}.Store.get(key)
      end
      """

      assert {:ok, _summary} = Code.define(code, [store, client], false, principal)
    end

    test "dropping a function a surviving caller uses is refused, world untouched", ctx do
      ns = unique_namespace()
      store = Module.concat([ns, Store])
      client = Module.concat([ns, Client])
      purge_on_exit([store, client])
      store_and_client(ctx.principal, ns, store, client)
      store_file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/store.ex")
      store_source = File.read!(store_file)

      breaking = """
      defmodule #{ns}.Store do
        @moduledoc "Store, without get."
        def put(key), do: {:ok, key}
      end
      """

      assert {:error, message} = Code.define(breaking, [store], true, ctx.principal)

      assert message ==
               "replacing #{ns}.Store broke its caller #{ns}.Client — #{ns}.Client calls " <>
                 "#{ns}.Store.get/1, which the replacement no longer defines. Nothing was " <>
                 "changed. Update #{ns}.Client in the same buffer, or keep #{ns}.Store.get/1."

      assert apply(store, :get, [:milk]) == {:ok, :milk}
      assert apply(client, :fetch, [:milk]) == {:ok, :milk}
      assert File.read!(store_file) == store_source
    end

    test "updating the caller in the same buffer lets the drop through", ctx do
      ns = unique_namespace()
      store = Module.concat([ns, Store])
      client = Module.concat([ns, Client])
      purge_on_exit([store, client])
      store_and_client(ctx.principal, ns, store, client)

      fixed = """
      defmodule #{ns}.Store do
        @moduledoc "Store, without get."
        def put(key), do: {:ok, key}
      end

      defmodule #{ns}.Client do
        @moduledoc "Client."
        def fetch(key), do: #{ns}.Store.put(key)
      end
      """

      assert {:ok, _summary} = Code.define(fixed, [store, client], true, ctx.principal)
      assert apply(client, :fetch, [:milk]) == {:ok, :milk}
      assert Code.calls()[client] == %{store => [put: 1]}
    end

    test "a compatible replace names its surviving runtime callers", ctx do
      ns = unique_namespace()
      store = Module.concat([ns, Store])
      client = Module.concat([ns, Client])
      purge_on_exit([store, client])
      store_and_client(ctx.principal, ns, store, client)

      compatible = """
      defmodule #{ns}.Store do
        @moduledoc "Store, evolved."
        def get(key), do: {:ok, {key, :fresh}}
        def put(key), do: {:ok, key}
      end
      """

      assert {:ok, summary} = Code.define(compatible, [store], true, ctx.principal)

      assert summary ==
               "Defined #{ns}.Store (replaced)\n" <>
                 "Note: called at runtime by #{ns}.Client (get/1)"
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

      assert {:ok, _summary} = Code.define(code, [mod], false, ctx.principal)
      source_file = Path.join(ctx.code_dir, "lib/#{Macro.underscore(ns)}/toss.ex")
      beam_file = Path.join(ctx.code_dir, "ebin/Elixir.#{ns}.Toss.beam")
      assert File.exists?(source_file)
      assert File.exists?(beam_file)

      assert :ok = Code.remove([mod], ctx.principal)

      refute loaded?(mod)
      refute File.exists?(source_file)
      refute File.exists?(beam_file)
      assert Code.defined() == []
      assert Code.deps() == %{}
      assert Code.calls() == %{}
    end

    test "a removal survives a restart", ctx do
      ns = unique_namespace()
      keep = Module.concat([ns, Keep])
      toss = Module.concat([ns, Toss])
      purge_on_exit([keep, toss])

      code = """
      defmodule #{ns}.Keep do
        @moduledoc "Keep."
        def hi, do: :hi
      end

      defmodule #{ns}.Toss do
        @moduledoc "Throwaway."
        def hi, do: :hi
      end
      """

      assert {:ok, _summary} = Code.define(code, [keep, toss], false, ctx.principal)
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

      code = """
      defmodule #{ns}.Store do
        @moduledoc "Store."
        def get(key), do: {:ok, key}
      end

      defmodule #{ns}.Client do
        @moduledoc "Client."
        def fetch(key), do: #{ns}.Store.get(key)
      end
      """

      assert {:ok, _summary} = Code.define(code, [store, client], false, ctx.principal)
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

      code = """
      defmodule #{ns}.Item do
        @moduledoc "An item."
        defstruct [:name]
      end

      defmodule #{ns}.Basket do
        @moduledoc "A basket."
        def sample, do: %#{ns}.Item{name: "milk"}
      end
      """

      assert {:ok, _summary} = Code.define(code, [item, basket], false, ctx.principal)
      assert {:error, message} = Code.remove([item], ctx.principal)
      assert message =~ "cannot remove #{ns}.Item — #{ns}.Basket depends on it at compile time."
    end

    test "mutual callers remove only as one set", ctx do
      ns = unique_namespace()
      ping = Module.concat([ns, Ping])
      pong = Module.concat([ns, Pong])
      purge_on_exit([ping, pong])

      code = """
      defmodule #{ns}.Ping do
        @moduledoc "Ping."
        def ping(0), do: :done
        def ping(n), do: #{ns}.Pong.pong(n - 1)
      end

      defmodule #{ns}.Pong do
        @moduledoc "Pong."
        def pong(0), do: :done
        def pong(n), do: #{ns}.Ping.ping(n - 1)
      end
      """

      assert {:ok, _summary} = Code.define(code, [ping, pong], false, ctx.principal)

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
end
