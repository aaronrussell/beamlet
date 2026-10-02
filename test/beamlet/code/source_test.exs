defmodule Beamlet.Code.SourceTest do
  use ExUnit.Case, async: true

  alias Beamlet.Code.Source

  @source ~S'''
  defmodule Shopping.List do
    @moduledoc """
    A list.
    """

    use Host.Web, :html

    @default_limit 10

    @doc """
    Total.
    """
    @spec total(list()) :: integer()
    def total(items) when is_list(items), do: Enum.sum(items)

    @spec total(map()) :: integer()
    def total(%{} = m), do: m |> Map.values() |> Enum.sum()

    # a comment that stays put
    @impl true
    def one, do: :ok

    attr :name, :string
    slot :inner_block

    def card(assigns) do
      ~H"""
      <div>{@name}</div>
      """
    end

    defguard is_pos(n) when n > 0
    defdelegate size(l), to: Enum, as: :count
    defmacro m(x), do: x

    defp helper(a), do: a
    defp helper(a, b), do: {a, b}

    def with_defaults(items, opts \\ []), do: {items, opts}

    defstruct [:a]
    @type t :: %__MODULE__{}
  end
  '''

  defp rows(source) do
    {:ok, items} = Source.outline(source)
    Enum.map(items, &{&1.kind, &1.label, &1.range, &1.clauses})
  end

  describe "outline/1" do
    test "lists every top-level item with its kind and range" do
      assert rows(@source) == [
               {:doc, ~s|@moduledoc """|, 2..4, nil},
               {:other, "use Host.Web, :html", 6..6, nil},
               {:attribute, "@default_limit 10", 8..8, nil},
               {:def, "def total/1", 10..17, 2},
               {:def, "def one/0", 20..21, 1},
               {:def, "def card/1", 23..30, 1},
               {:defguard, "defguard is_pos/1", 32..32, 1},
               {:defdelegate, "defdelegate size/1", 33..33, 1},
               {:defmacro, "defmacro m/1", 34..34, 1},
               {:defp, "defp helper/1", 36..36, 1},
               {:defp, "defp helper/2", 37..37, 1},
               {:def, "def with_defaults/2", 39..39, 1},
               {:other, "defstruct [:a]", 41..41, nil},
               {:type, "@type t", 42..42, nil}
             ]
    end

    test "a typedoc rolls into its type and a doc into its callback" do
      source = """
      defmodule A do
        @behaviour Access

        @typedoc "An id."
        @type id :: pos_integer()
        @typep secret(t) :: {t, binary()}
        @opaque handle :: reference()

        @doc "Called to start."
        @callback start(id(), keyword()) :: :ok
        @macrocallback build(term()) :: Macro.t() when term: any()

        @derive Jason.Encoder
        @enforce_keys [:id]
        defstruct [:id]
      end
      """

      assert rows(source) == [
               {:other, "@behaviour Access", 2..2, nil},
               {:type, "@type id", 4..5, nil},
               {:type, "@typep secret", 6..6, nil},
               {:type, "@opaque handle", 7..7, nil},
               {:callback, "@callback start/2", 9..10, nil},
               {:callback, "@macrocallback build/1", 11..11, nil},
               {:attribute, "@derive Jason.Encoder", 13..13, nil},
               {:attribute, "@enforce_keys [:id]", 14..14, nil},
               {:other, "defstruct [:id]", 15..15, nil}
             ]
    end

    test "an item's text is its lines verbatim" do
      {:ok, items} = Source.outline(@source)
      one = Enum.find(items, &(&1.label == "def one/0"))

      assert one.text == "  @impl true\n  def one, do: :ok"
    end

    test "a long header item is cut to the label width" do
      source = """
      defmodule A do
        @moduledoc "A moduledoc long enough to run past the sixty characters the outline shows"
      end
      """

      assert [{:doc, label, 2..2, nil}] = rows(source)
      assert String.length(label) == 60
      assert String.ends_with?(label, "...")
    end

    test "a one-form module body" do
      source = """
      defmodule A do
        @moduledoc "One."
      end
      """

      assert rows(source) == [{:doc, ~s|@moduledoc "One."|, 2..2, nil}]
    end

    test "a nested module and a comprehension are items of their own" do
      source = """
      defmodule A do
        defmodule B do
          def b, do: 1
        end

        for k <- [:x, :y] do
          def unquote(k)(), do: unquote(k)
        end

        def unquote(:z)(), do: 1
      end
      """

      assert rows(source) == [
               {:other, "defmodule B do", 2..4, nil},
               {:other, "for k <- [:x, :y] do", 6..8, nil},
               {:other, "def unquote(:z)(), do: 1", 10..10, nil}
             ]
    end

    test "attachments above a non-definer are orphaned docs of their own" do
      source = """
      defmodule A do
        @doc "Orphaned."
        @spec x :: 1
        @limit 1
        def x, do: @limit
      end
      """

      assert rows(source) == [
               {:doc, ~s|@doc "Orphaned."|, 2..2, nil},
               {:doc, "@spec x :: 1", 3..3, nil},
               {:attribute, "@limit 1", 4..4, nil},
               {:def, "def x/0", 5..5, 1}
             ]
    end

    test "scattered clauses list twice" do
      source = """
      defmodule A do
        def a(1), do: 1
        def b, do: 2
        def a(2), do: 2
      end
      """

      assert rows(source) == [
               {:def, "def a/1", 2..2, 1},
               {:def, "def b/0", 3..3, 1},
               {:def, "def a/1", 4..4, 1}
             ]
    end

    test "a source that does not parse names the line" do
      assert {:error, {1, "missing terminator: end"}} =
               Source.outline("defmodule A do\n  def x do\nend\n")

      assert {:error, {2, "unexpected reserved word: end"}} =
               Source.outline("defmodule A do\n  def x(, do: 1\nend\n")
    end
  end

  describe "select/3" do
    test "finds a function's block" do
      assert {:ok, %{label: "def total/1", range: 10..17, clauses: 2}} =
               Source.select(@source, "total", 1)
    end

    test "an unknown function lists the module's functions" do
      assert {:error, :not_found, functions} = Source.select(@source, "total", 3)

      assert functions == [
               "total/1",
               "one/0",
               "card/1",
               "is_pos/1",
               "size/1",
               "m/1",
               "helper/1",
               "helper/2",
               "with_defaults/2"
             ]
    end

    test "a scattered function is refused" do
      source = """
      defmodule A do
        def a(1), do: 1
        def b, do: 2
        def a(2), do: 2
      end
      """

      assert {:error, :scattered} = Source.select(source, "a", 1)
      assert {:ok, %{range: 3..3}} = Source.select(source, "b", 0)
    end
  end

  describe "patch_find/3" do
    @small """
    defmodule A do
      def a, do: 1
      def b, do: 2
    end
    """

    test "replaces, inserts before and inserts after, with no separator" do
      assert Source.patch_find(@small, "def a, do: 1", {:replace, "def a, do: 10"}) ==
               {:ok, "defmodule A do\n  def a, do: 10\n  def b, do: 2\nend\n"}

      assert Source.patch_find(@small, "def b", {:before, "def z, do: 0\n  "}) ==
               {:ok, "defmodule A do\n  def a, do: 1\n  def z, do: 0\n  def b, do: 2\nend\n"}

      assert Source.patch_find(@small, "def b, do: 2", {:after, "\n  def c, do: 3"}) ==
               {:ok, "defmodule A do\n  def a, do: 1\n  def b, do: 2\n  def c, do: 3\nend\n"}
    end

    test "an empty replacement removes the text" do
      assert Source.patch_find(@small, "  def a, do: 1\n", {:replace, ""}) ==
               {:ok, "defmodule A do\n  def b, do: 2\nend\n"}
    end

    test "text that does not occur is not found" do
      assert Source.patch_find(@small, "def q", {:replace, ""}) == {:error, :not_found}
    end

    test "text that matches once with leading whitespace ignored is indented" do
      assert Source.patch_find(@small, "def a, do: 1\ndef b, do: 2", {:replace, ""}) ==
               {:error, :indented}

      assert Source.patch_find(@small, "  ", {:replace, ""}) == {:error, {:several, 2}}
    end

    test "text occurring more than once gives the count" do
      assert Source.patch_find(@small, "do:", {:replace, ""}) == {:error, {:several, 2}}
    end
  end

  describe "patch_select/4" do
    test "replaces a function's block, docs included" do
      assert {:ok, patched} =
               Source.patch_select(@source, "one", 0, {:replace, "\n\n  def one, do: :one\n"})

      assert Source.lines(patched, 19..21) ==
               "  # a comment that stays put\n  def one, do: :one\n"

      assert {:ok, %{range: 20..20, clauses: 1}} = Source.select(patched, "one", 0)
      assert {:ok, %{range: 10..17}} = Source.select(patched, "total", 1)
    end

    test "an empty replacement removes the block and leaves the neighbours" do
      assert {:ok, patched} = Source.patch_select(@source, "one", 0, {:replace, ""})
      assert {:error, :not_found, _functions} = Source.select(patched, "one", 0)
      assert Source.lines(patched, 18..20) == "\n  # a comment that stays put\n"
      assert {:ok, %{range: 21..28}} = Source.select(patched, "card", 1)
    end

    test "before inserts above the block's docs and after below its last clause" do
      assert {:ok, patched} = Source.patch_select(@source, "total", 1, {:before, "def z, do: 0"})
      assert Source.lines(patched, 10..12) == "def z, do: 0\n\n  @doc \"\"\""

      assert {:ok, patched} = Source.patch_select(@source, "total", 1, {:after, "def z, do: 0"})

      assert Source.lines(patched, 17..19) ==
               "  def total(%{} = m), do: m |> Map.values() |> Enum.sum()\n\ndef z, do: 0"
    end

    test "an unknown function lists the module's functions" do
      assert {:error, :not_found, ["total/1" | _rest]} =
               Source.patch_select(@source, "nope", 1, {:replace, ""})
    end

    test "a scattered function and a source that does not parse are refused" do
      scattered = "defmodule A do\n  def a(1), do: 1\n  def b, do: 2\n  def a(2), do: 2\nend\n"
      assert {:error, :scattered} = Source.patch_select(scattered, "a", 1, {:replace, ""})

      assert {:error, {2, _message}} =
               Source.patch_select(
                 "defmodule A do\n  def x(, do: 1\nend\n",
                 "x",
                 0,
                 {:replace, ""}
               )
    end
  end

  describe "lines/2 and line_count/1" do
    test "slices inclusive 1-based lines" do
      assert Source.lines(@source, 6..8) == "  use Host.Web, :html\n\n  @default_limit 10"
      assert Source.line_count(@source) == 43
    end
  end

  describe "diff/2" do
    @old """
    defmodule A do
      @moduledoc "A."

      @doc "Load."
      def load(id), do: id

      @doc "List."
      def list, do: []

      @doc "Total."
      def total(x), do: x

      @doc "Render."
      def render(x), do: x

      defp keep, do: :ok
    end
    """

    test "names what was removed, changed and added, in source order" do
      new = """
      defmodule A do
        @moduledoc "A."

        @doc "Total."
        def total(x) when is_list(x), do: Enum.sum(x)
        def total(x), do: x

        @doc "Rendered."
        def render(x), do: x

        defp keep, do: :ok

        @doc "Remove."
        def remove(a, b), do: {a, b}
      end
      """

      assert {:ok, %{removed: removed, changed: changed, new: added}} = Source.diff(@old, new)
      assert Enum.map(removed, &Source.fa/1) == ["load/1", "list/0"]

      assert Enum.map(changed, fn {_before, item} -> Source.fa(item) end) == [
               "total/1",
               "render/1"
             ]

      assert Enum.map(added, &Source.fa/1) == ["remove/2"]

      assert Source.render_diff(Source.diff(@old, new)) == [
               "  - removed load/1, list/0",
               "  - changed total/1 (1 to 2 clauses), render/1",
               "  - new remove/2"
             ]
    end

    test "identical source is unchanged" do
      assert Source.diff(@old, @old) == :unchanged
      assert Source.render_diff(:unchanged) == ["  - unchanged"]
    end

    test "a header-only edit changes no function" do
      new = String.replace(@old, ~s|@moduledoc "A."|, ~s|@moduledoc "A list."|)

      assert {:ok, %{removed: [], changed: [], new: []}} = Source.diff(@old, new)
      assert Source.render_diff(Source.diff(@old, new)) == ["  - no function changes"]
    end

    test "a previous source that does not parse has nothing to compare" do
      assert Source.diff("defmodule A do\n  def x do\nend\n", @old) == {:error, :unparseable}

      assert Source.render_diff({:error, :unparseable}) ==
               ["  - previous source did not parse, so nothing to compare"]
    end

    test "a scattered function in the old source counts as one" do
      old = """
      defmodule A do
        def a(1), do: 1
        def b, do: 2
        def a(2), do: 2
      end
      """

      gathered = """
      defmodule A do
        def a(1), do: 1
        def a(2), do: 2
        def b, do: 2
      end
      """

      assert Source.render_diff(Source.diff(old, gathered)) == ["  - no function changes"]

      trimmed = """
      defmodule A do
        def a(1), do: 1
        def b, do: 2
      end
      """

      assert {:ok, %{changed: [{before, after_}]}} = Source.diff(old, trimmed)
      assert before.clauses == 2
      assert after_.clauses == 1
      assert Source.render_diff(Source.diff(old, trimmed)) == ["  - changed a/1 (2 to 1 clauses)"]
    end
  end
end
