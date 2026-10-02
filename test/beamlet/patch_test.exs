defmodule Beamlet.PatchTest do
  use Beamlet.Case

  import ExUnit.CaptureIO

  alias Beamlet.Code
  alias Beamlet.Define
  alias Beamlet.Patch

  setup %{token: token, data_dir: data_dir} do
    %{principal: principal(token), code_dir: Path.join(data_dir, "code")}
  end

  @list """
  defmodule NS.List do
    @moduledoc "A shopping list."

    @doc "Loads a list."
    def load(id), do: {:ok, id}

    @doc "Totals the items."
    def total(items), do: Enum.sum(items)

    @doc "Renders the items."
    def render(items), do: Enum.join(items, ", ")
  end
  """

  defp list_module(ctx) do
    ns = unique_namespace()
    mod = Module.concat([ns, List])
    purge_on_exit([mod])
    {:ok, _summary} = Define.run([%{code: String.replace(@list, "NS", ns)}], ctx.principal)
    {ns, mod}
  end

  # Modules are named as the tool passes them, by string; a test
  # passes the atom and the helper spells it.
  defp patch(patches, principal, opts \\ []) do
    patches =
      Enum.map(patches, fn
        %{module: mod} = patch when is_atom(mod) -> %{patch | module: inspect(mod)}
        patch -> patch
      end)

    quiet(fn -> Patch.run(patches, principal, opts) end)
  end

  defp patch_error(patches, principal, opts \\ []) do
    assert {:error, message} = patch(patches, principal, opts)
    message
  end

  defp stored(ctx, mod) do
    File.read!(Path.join(ctx.code_dir, "lib/#{Macro.underscore(mod)}.ex"))
  end

  defp restart_code_server do
    :ok = Supervisor.terminate_child(Beamlet, Code)
    {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)
  end

  defp quarantine(ctx, file, source) do
    File.write!(Path.join(ctx.code_dir, file), source)
    ExUnit.CaptureLog.capture_log(fn -> quiet(fn -> restart_code_server() end) end)
  end

  describe "find" do
    test "replace swaps the text and the summary says what changed", ctx do
      {_ns, mod} = list_module(ctx)

      assert {:ok, summary} =
               patch(
                 [%{module: mod, find: "Enum.sum(items)", replace: "Enum.sum(items) * 2"}],
                 ctx.principal
               )

      assert summary == "Patched #{inspect(mod)}\n  - changed total/1"
      assert apply(mod, :total, [[1, 2]]) == 6
      assert stored(ctx, mod) =~ "def total(items), do: Enum.sum(items) * 2\n"
    end

    test "before and after insert around the text, and the result is stored formatted", ctx do
      {_ns, mod} = list_module(ctx)

      assert {:ok, summary} =
               patch(
                 [
                   %{
                     module: mod,
                     find: "  @doc \"Renders the items.\"",
                     before: "@doc \"Counts.\"\n  def count(items),   do: length(items)\n\n"
                   },
                   %{
                     module: mod,
                     find: "def render(items), do: Enum.join(items, \", \")",
                     after: "\n\n  @doc \"Empties.\"\n  def empty, do: []"
                   }
                 ],
                 ctx.principal
               )

      assert summary == "Patched #{inspect(mod)}\n  - new count/1, empty/0"
      assert apply(mod, :count, [[1, 2, 3]]) == 3
      assert stored(ctx, mod) =~ "  def count(items), do: length(items)\n\n"
    end

    test "an empty replace removes the text", ctx do
      {_ns, mod} = list_module(ctx)

      assert {:ok, summary} =
               patch(
                 [
                   %{
                     module: mod,
                     find: "  @doc \"Loads a list.\"\n  def load(id), do: {:ok, id}\n\n",
                     replace: ""
                   }
                 ],
                 ctx.principal
               )

      assert summary == "Patched #{inspect(mod)}\n  - removed load/1"
      refute function_exported?(mod, :load, 1)
    end

    test "no match names the patch and says source is stored formatted", ctx do
      {_ns, mod} = list_module(ctx)

      message = patch_error([%{module: mod, find: "def total(x)", replace: ""}], ctx.principal)

      assert message ==
               "patch 1 (#{inspect(mod)}, find \"def total(x)\"): no match — quote text " <>
                 "exactly as Host.Code.print_source prints it. Source is stored formatted, " <>
                 "so it may differ from the code you passed to define."
    end

    test "code passed to define that the formatter changed does not match", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Loose])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Loose do
        @moduledoc "Loosely written."

        @doc "Totals."
        def total(items),   do: Enum.sum( items )
      end
      """

      assert {:ok, _summary} = Define.run([%{code: code}], ctx.principal)

      message =
        patch_error(
          [%{module: mod, find: "def total(items),   do: Enum.sum( items )", replace: ""}],
          ctx.principal
        )

      assert message =~
               "patch 1 (#{inspect(mod)}, find \"def total(items),   do: Enum.sum( items )\"): no match"

      assert message =~ "Source is stored formatted"
      assert stored(ctx, mod) =~ "def total(items), do: Enum.sum(items)"
    end

    test "a match with leading whitespace ignored is pointed out", ctx do
      {_ns, mod} = list_module(ctx)

      message =
        patch_error(
          [%{module: mod, find: "@doc \"Totals the items.\"\ndef total(items)", replace: ""}],
          ctx.principal
        )

      assert message =~
               "patch 1 (#{inspect(mod)}, find \"@doc \\\"Totals the items.\\\"\"): no exact " <>
                 "match, though the text matches once with leading whitespace ignored — quote " <>
                 "it with its indentation"
    end

    test "several matches give the count", ctx do
      {_ns, mod} = list_module(ctx)

      assert patch_error([%{module: mod, find: "items", replace: "list"}], ctx.principal) ==
               "patch 1 (#{inspect(mod)}, find \"items\"): the text occurs 6 times — quote " <>
                 "more context, so it occurs once"
    end

    test "a long first line is cut in the label", ctx do
      {_ns, mod} = list_module(ctx)
      long = String.duplicate("x", 70)

      assert patch_error([%{module: mod, find: long, replace: ""}], ctx.principal) =~
               "patch 1 (#{inspect(mod)}, find \"#{String.duplicate("x", 57)}...\"): no match"
    end
  end

  describe "select" do
    test "replace swaps the block, docs included, with the clause count", ctx do
      {_ns, mod} = list_module(ctx)

      assert {:ok, summary} =
               patch(
                 [
                   %{
                     module: mod,
                     select: "total/1",
                     replace: """

                     @doc "Totals the items, or a map's values."
                     def total(items) when is_list(items), do: Enum.sum(items)
                     def total(%{} = map), do: map |> Map.values() |> Enum.sum()

                     """
                   }
                 ],
                 ctx.principal
               )

      assert summary == "Patched #{inspect(mod)}\n  - changed total/1 (1 to 2 clauses)"
      assert apply(mod, :total, [%{a: 1, b: 2}]) == 3

      assert stored(ctx, mod) =~
               "  def load(id), do: {:ok, id}\n\n  @doc \"Totals the items, or a map's values.\"\n"
    end

    test "an empty replace removes the block", ctx do
      {_ns, mod} = list_module(ctx)

      assert {:ok, summary} =
               patch([%{module: mod, select: "load/1", replace: ""}], ctx.principal)

      assert summary == "Patched #{inspect(mod)}\n  - removed load/1"

      assert stored(ctx, mod) =~
               "  @moduledoc \"A shopping list.\"\n\n  @doc \"Totals the items.\"\n"
    end

    test "before inserts above the docs and after below the last clause", ctx do
      {_ns, mod} = list_module(ctx)

      assert {:ok, summary} =
               patch(
                 [
                   %{
                     module: mod,
                     select: "total/1",
                     before: "@doc \"Counts.\"\ndef count(items), do: length(items)"
                   },
                   %{
                     module: mod,
                     select: "total/1",
                     after: "@doc \"Empties.\"\ndef empty, do: []"
                   }
                 ],
                 ctx.principal
               )

      assert summary == "Patched #{inspect(mod)}\n  - new count/1, empty/0"

      assert stored(ctx, mod) =~
               Enum.join(
                 [
                   "  @doc \"Counts.\"",
                   "  def count(items), do: length(items)",
                   "",
                   "  @doc \"Totals the items.\"",
                   "  def total(items), do: Enum.sum(items)",
                   "",
                   "  @doc \"Empties.\"",
                   "  def empty, do: []",
                   "",
                   "  @doc \"Renders the items.\""
                 ],
                 "\n"
               )
    end

    test "a function an earlier patch adds can be selected by a later one", ctx do
      {_ns, mod} = list_module(ctx)
      name = "added_#{System.unique_integer([:positive])}"

      assert {:ok, _summary} =
               patch(
                 [
                   %{module: mod, select: "total/1", after: "@doc \"One.\"\ndef #{name}, do: 1"},
                   %{
                     module: mod,
                     select: "#{name}/0",
                     replace: "@doc \"Two.\"\ndef #{name}, do: 2"
                   }
                 ],
                 ctx.principal
               )

      assert apply(mod, String.to_atom(name), []) == 2
    end

    test "an unknown function name makes no atom", ctx do
      {_ns, mod} = list_module(ctx)
      name = "never_seen_#{System.unique_integer([:positive])}"

      assert patch_error([%{module: mod, select: "#{name}/0", replace: ""}], ctx.principal) =~
               "has no function #{name}/0"

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "an unknown function lists the module's functions", ctx do
      {_ns, mod} = list_module(ctx)

      assert patch_error([%{module: mod, select: "total/2", replace: ""}], ctx.principal) ==
               "patch 1 (#{inspect(mod)}, select total/2): #{inspect(mod)} has no function " <>
                 "total/2 — Host.Code.print_outline(#{inspect(mod)}) lists what it has: " <>
                 "load/1, total/1, render/1"
    end

    test "a scattered function in a quarantined module is refused, pointing at find", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Scattered])
      purge_on_exit([mod])

      quarantine(ctx, "lib/scattered.ex", """
      defmodule #{ns}.Scattered do
        @moduledoc "Scattered by hand."
        def size(1), do: 1
        def other, do: :ok
        def size(2), do: 2
      end
      """)

      assert [%{modules: [^mod]}] = Code.quarantined()

      assert patch_error([%{module: mod, select: "size/1", replace: ""}], ctx.principal) ==
               "patch 1 (#{inspect(mod)}, select size/1): #{inspect(mod)}.size/1 has clauses " <>
                 "separated by other definitions, so select cannot take it as one block — " <>
                 "patch the clauses with find"
    end
  end

  describe "the transaction" do
    test "two patches to one module land together, the first calling what the second adds",
         ctx do
      {_ns, mod} = list_module(ctx)

      assert {:ok, summary} =
               patch(
                 [
                   %{module: mod, find: "Enum.sum(items)", replace: "subtotal(items) * 2"},
                   %{
                     module: mod,
                     select: "total/1",
                     after: "defp subtotal(items), do: Enum.sum(items)"
                   }
                 ],
                 ctx.principal
               )

      assert summary == "Patched #{inspect(mod)}\n  - changed total/1\n  - new subtotal/1"
      assert apply(mod, :total, [[1, 2]]) == 6
    end

    test "each patch sees the text the previous one left", ctx do
      {_ns, mod} = list_module(ctx)

      assert {:ok, _summary} =
               patch(
                 [
                   %{module: mod, find: "Enum.sum(items)", replace: "Enum.sum(items) + 1"},
                   %{module: mod, find: "+ 1", replace: "+ 2"}
                 ],
                 ctx.principal
               )

      assert apply(mod, :total, [[1]]) == 3
    end

    test "two modules in one call compile together", ctx do
      {ns, list} = list_module(ctx)
      cart = Module.concat([ns, Cart])
      purge_on_exit([cart])

      assert {:ok, _summary} =
               Define.run(
                 [
                   %{
                     code: """
                     defmodule #{ns}.Cart do
                       @moduledoc "A cart."

                       @doc "The cart's total."
                       def total(items), do: #{ns}.List.total(items)
                     end
                     """
                   }
                 ],
                 ctx.principal
               )

      assert {:ok, summary} =
               patch(
                 [
                   %{
                     module: cart,
                     find: "#{ns}.List.total(items)",
                     replace: "#{ns}.List.count(items)"
                   },
                   %{
                     module: list,
                     select: "render/1",
                     after: "@doc \"Counts.\"\ndef count(items), do: length(items)"
                   }
                 ],
                 ctx.principal
               )

      assert summary ==
               Enum.join(
                 [
                   "Patched #{inspect(cart)}",
                   "  - changed total/1",
                   "Patched #{inspect(list)}",
                   "  - new count/1"
                 ],
                 "\n"
               )

      assert apply(cart, :total, [[5, 5]]) == 2
    end

    test "a failing second patch fails the call with nothing changed", ctx do
      {_ns, mod} = list_module(ctx)
      before = stored(ctx, mod)

      message =
        patch_error(
          [
            %{module: mod, find: "Enum.sum(items)", replace: "Enum.sum(items) * 2"},
            %{module: mod, find: "nowhere", replace: ""}
          ],
          ctx.principal
        )

      assert message =~ "patch 2 (#{inspect(mod)}, find \"nowhere\"): no match"
      assert stored(ctx, mod) == before
      assert apply(mod, :total, [[1, 2]]) == 3
    end

    test "a result that stops parsing is refused at that patch, with context lines", ctx do
      {_ns, mod} = list_module(ctx)

      message =
        patch_error(
          [
            %{
              module: mod,
              find: "def total(items), do: Enum.sum(items)",
              replace: "def total(items) do"
            }
          ],
          ctx.principal
        )

      assert message =~
               "patch 1 (#{inspect(mod)}, find \"def total(items), do: Enum.sum(items)\"): the " <>
                 "result does not parse — lib/#{Macro.underscore(mod)}.ex:"

      assert message =~ ~r/^\s+\d+ \| /m
    end

    test "a compile error carries the label and quotes two lines either side", ctx do
      {_ns, mod} = list_module(ctx)

      message =
        patch_error(
          [
            %{
              module: mod,
              select: "total/1",
              replace: """
              @doc "Totals the items."
              def total(items) do
                items
                |> subtotal()
                |> Enum.sum()
              end
              """
            }
          ],
          ctx.principal
        )

      path = "lib/#{Macro.underscore(mod)}.ex"

      assert message =~
               "patch 1 (#{inspect(mod)}, select total/1): #{path}:10: undefined function subtotal/1"

      assert message =~
               Enum.join(
                 [
                   "     8 |   def total(items) do",
                   "     9 |     items",
                   "    10 |     |> subtotal()",
                   "    11 |     |> Enum.sum()",
                   "    12 |   end"
                 ],
                 "\n"
               )

      assert apply(mod, :total, [[1, 2]]) == 3
    end

    test "a module several patches touched is labelled by all of them", ctx do
      {_ns, mod} = list_module(ctx)

      message =
        patch_error(
          [
            %{module: mod, find: "Enum.sum(items)", replace: "subtotal(items)"},
            %{module: mod, find: "Enum.join(items, \", \")", replace: "Enum.join(items, sep())"}
          ],
          ctx.principal
        )

      assert message =~ "patches 1 and 2 (#{inspect(mod)}): lib/"
    end

    test "a scanner refusal carries the label and the context", ctx do
      {_ns, mod} = list_module(ctx)

      message =
        patch_error(
          [%{module: mod, find: "{:ok, id}", replace: "System.cmd(\"ls\", [])"}],
          ctx.principal
        )

      assert message =~ "patch 1 (#{inspect(mod)}, find \"{:ok, id}\"): lib/"

      assert message =~
               "    4 |   @doc \"Loads a list.\"\n    5 |   def load(id), do: System.cmd(\"ls\", [])\n    6 |\n"
    end

    test "a docs refusal carries the label", ctx do
      {_ns, mod} = list_module(ctx)

      message =
        patch_error(
          [%{module: mod, select: "render/1", after: "def undocumented, do: :ok"}],
          ctx.principal
        )

      assert message ==
               "patch 1 (#{inspect(mod)}, select render/1): #{inspect(mod)}.undocumented/0 " <>
                 "is missing @doc — document every public function (argument and return " <>
                 "shapes belong here)"
    end

    test "a patch whose result equals the source is unchanged", ctx do
      {_ns, mod} = list_module(ctx)

      assert {:ok, summary} =
               patch(
                 [%{module: mod, find: "Enum.sum(items)", replace: "Enum.sum(items)"}],
                 ctx.principal
               )

      assert summary == "Patched #{inspect(mod)}\n  - unchanged"
    end

    test "the timeout rides the options", ctx do
      {_ns, mod} = list_module(ctx)

      message =
        patch_error(
          [
            %{
              module: mod,
              select: "render/1",
              after: "Enum.each(1..5_000_000_000, fn _ -> :ok end)"
            }
          ],
          ctx.principal,
          timeout: 50
        )

      assert message =~ "patch timed out after 50ms"
    end

    test "an empty list is refused", ctx do
      assert patch_error([], ctx.principal) ==
               "patch names no modules — pass one patch per change"
    end
  end

  describe "the shape of a patch" do
    test "every refusal comes back together, in patch order", ctx do
      {ns, mod} = list_module(ctx)
      other = Module.concat([ns, Missing])

      message =
        patch_error(
          [
            %{module: mod, find: "a", select: "total/1", replace: ""},
            %{module: mod, replace: ""},
            %{module: mod, find: "a", replace: "", after: "b"},
            %{module: mod, find: "a"},
            %{module: mod, find: "", replace: ""},
            %{module: mod, select: "total", replace: ""},
            %{module: mod, find: "a", after: ""},
            %{module: other, find: "a", replace: ""},
            %{module: Enum, find: "a", replace: ""},
            %{module: "", find: "a", replace: ""}
          ],
          ctx.principal
        )

      rule =
        "one anchor per patch: find, text occurring exactly once in the module's source, or " <>
          "select, a function as name/arity"

      assert message ==
               Enum.join(
                 [
                   "patch 1 has both find and select — #{rule}",
                   "patch 2 has no anchor — #{rule}",
                   "patch 3 has replace and after — one operation per patch: replace (empty " <>
                     "removes), before or after",
                   "patch 4 has no operation — one operation per patch: replace (empty " <>
                     "removes), before or after",
                   "patch 5: find is empty — quote text occurring exactly once in the " <>
                     "module's current source",
                   "patch 6: select \"total\" is not a function as name/arity — spell it as " <>
                     "Host.Code.print_outline lists it, like total/1",
                   "patch 7: after is empty — nothing to insert; replace with empty text " <>
                     "removes the anchor",
                   "patch 8: #{inspect(other)} is not a defined module — " <>
                     "Host.Code.print_modules() shows what is",
                   "patch 9: Enum is part of your beamlet, not a defined module — patch " <>
                     "edits modules defined with define; Host.Code.print_modules() shows them",
                   "patch 10 names no module — each patch names the module it edits"
                 ],
                 "\n"
               )
    end

    test "an unknown module name makes no atom", ctx do
      name = "NeverSeen#{System.unique_integer([:positive])}.Mod"

      assert patch_error([%{module: name, find: "a", replace: ""}], ctx.principal) ==
               "patch 1: #{name} is not a defined module — Host.Code.print_modules() shows what is"

      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
    end

    test "changing the defmodule line's name is refused", ctx do
      {ns, mod} = list_module(ctx)

      assert patch_error(
               [%{module: mod, find: "defmodule #{ns}.List", replace: "defmodule #{ns}.Lists"}],
               ctx.principal
             ) ==
               "patch 1 (#{inspect(mod)}, find \"defmodule #{ns}.List\") changed the defmodule " <>
                 "line from #{inspect(mod)} to #{ns}.Lists — the pipeline would file a new " <>
                 "module and leave the old. Keep the name; to rename, define #{ns}.Lists and " <>
                 "remove #{inspect(mod)}."
    end
  end

  describe "quarantined modules" do
    test "a broken module is repaired by find and compared with its quarantined source", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Broken])
      purge_on_exit([mod])

      quarantine(ctx, "lib/broken.ex", """
      defmodule #{ns}.Broken do
        @moduledoc "Broken by hand."

        @doc "Loads."
        def load(id), do: undefined_local(id)
      end
      """)

      assert [%{modules: [^mod]}] = Code.quarantined()

      assert {:ok, summary} =
               patch(
                 [%{module: mod, find: "undefined_local(id)", replace: "{:ok, id}"}],
                 ctx.principal
               )

      assert summary == "Patched #{inspect(mod)}\n  - changed load/1"
      assert Code.quarantined() == []
      assert apply(mod, :load, [1]) == {:ok, 1}
      refute File.exists?(Path.join(ctx.code_dir, "lib/broken.ex"))
      assert stored(ctx, mod) =~ "def load(id), do: {:ok, id}"
    end

    test "two broken modules that call each other are repaired in one call", ctx do
      ns = unique_namespace()
      a = Module.concat([ns, Ping])
      b = Module.concat([ns, Pong])
      purge_on_exit([a, b])

      File.write!(Path.join(ctx.code_dir, "lib/ping.ex"), """
      defmodule #{ns}.Ping do
        @moduledoc "Calls Pong."

        @doc "Pings."
        def ping(0), do: undefined_ping()
        def ping(n), do: #{ns}.Pong.pong(n - 1)
      end
      """)

      quarantine(ctx, "lib/pong.ex", """
      defmodule #{ns}.Pong do
        @moduledoc "Calls Ping."

        @doc "Pongs."
        def pong(0), do: undefined_pong()
        def pong(n), do: #{ns}.Ping.ping(n - 1)
      end
      """)

      assert [%{modules: [^a]}, %{modules: [^b]}] = Code.quarantined()

      assert {:ok, _summary} =
               patch(
                 [
                   %{module: a, find: "undefined_ping()", replace: ":ping"},
                   %{module: b, find: "undefined_pong()", replace: ":pong"}
                 ],
                 ctx.principal
               )

      assert Code.quarantined() == []
      assert apply(a, :ping, [3]) == :pong
    end

    test "a torn module refuses select and is repaired across two finds", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Torn])
      purge_on_exit([mod])

      quarantine(ctx, "lib/torn.ex", """
      defmodule #{ns}.Torn do
        @moduledoc "Torn by hand."

        @doc "Loads."
        def load(id) do
          {:ok, id

        @doc "Totals."
        def total(items), do: Enum.sum(items
      end
      """)

      assert [%{modules: [^mod]}] = Code.quarantined()

      message = patch_error([%{module: mod, select: "load/1", replace: ""}], ctx.principal)

      assert message =~
               "patch 1 (#{inspect(mod)}, select load/1): #{inspect(mod)} does not parse, so " <>
                 "select cannot find load/1 — lib/torn.ex:"

      assert message =~
               "Repair it with find, or read it by line range: " <>
                 "Host.Code.print_source(#{inspect(mod)}, 1..10)"

      message =
        patch_error(
          [%{module: mod, find: "{:ok, id\n", replace: "{:ok, id}\n  end\n"}],
          ctx.principal
        )

      assert message =~
               "#{inspect(mod)} did not parse before this call and still does not after " <>
                 "patch 1: lib/torn.ex:"

      assert message =~ "Read it by line range: Host.Code.print_source(#{inspect(mod)}, 1..11)"

      assert {:ok, summary} =
               patch(
                 [
                   %{module: mod, find: "{:ok, id\n", replace: "{:ok, id}\n  end\n"},
                   %{module: mod, find: "Enum.sum(items\n", replace: "Enum.sum(items)\n"}
                 ],
                 ctx.principal
               )

      assert summary ==
               "Patched #{inspect(mod)}\n  - previous source did not parse, so nothing to compare"

      assert Code.quarantined() == []
      assert apply(mod, :total, [[1, 2]]) == 3
    end

    test "a stray end refuses select with the parser's error and is repaired by find", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Stray])
      purge_on_exit([mod])

      quarantine(ctx, "lib/stray.ex", """
      defmodule #{ns}.Stray do
        @moduledoc "A stray end."
        @doc "The size."
        def size, do: 1
        end
      end
      """)

      assert [%{modules: [^mod]}] = Code.quarantined()

      message = patch_error([%{module: mod, select: "size/0", replace: ""}], ctx.principal)

      assert message =~
               "patch 1 (#{inspect(mod)}, select size/0): #{inspect(mod)} does not parse, so " <>
                 "select cannot find size/0 — lib/stray.ex:6: unexpected reserved word: end"

      assert {:ok, summary} =
               patch(
                 [%{module: mod, find: "do: 1\n  end\n", replace: "do: 1\n"}],
                 ctx.principal
               )

      assert summary ==
               "Patched #{inspect(mod)}\n  - previous source did not parse, so nothing to compare"

      assert Code.quarantined() == []
      assert apply(mod, :size, []) == 1
    end
  end

  describe "migrations" do
    defp migration(mod, table) do
      """
      defmodule #{inspect(mod)} do
        @moduledoc "Creates the #{table} table."
        use Ecto.Migration

        def change do
          create table(:#{table}) do
            add :name, :string
          end
        end
      end
      """
    end

    test "a pending migration is patchable and an applied one is refused", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, CreateThings])
      purge_on_exit([mod])
      table = "#{Macro.underscore(ns)}_things"

      assert {:ok, _summary} = Define.run([%{code: migration(mod, table)}], ctx.principal)

      assert {:ok, summary} =
               patch(
                 [%{module: mod, find: "add :name, :string", replace: "add :name, :text"}],
                 ctx.principal
               )

      assert summary ==
               "Patched #{inspect(mod)} — migration 1, pending: run Host.Migrator.migrate()\n" <>
                 "  - changed change/0"

      assert File.read!(
               Path.join(ctx.code_dir, "migrations/0001_#{Macro.underscore(ns)}_create_things.ex")
             ) =~
               "add :name, :text"

      capture_io(fn -> Host.Migrator.migrate() end)

      assert patch_error(
               [%{module: mod, find: "add :name, :text", replace: "add :name, :string"}],
               ctx.principal
             ) ==
               "cannot patch #{inspect(mod)} — migration 1 is applied. Roll it back first " <>
                 "with Host.Migrator.rollback(), then patch it."
    end
  end
end
