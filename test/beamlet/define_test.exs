defmodule Beamlet.DefineTest do
  # Loaded modules and the compiler tracer option are VM-global.
  use Beamlet.Case, async: false

  alias Beamlet.Code
  alias Beamlet.Code.Format
  alias Beamlet.Define
  alias Beamlet.Eval
  alias Beamlet.Tokens

  setup %{token: token} do
    %{principal: principal(token)}
  end

  # One module per call, the common case; `replace:` rides the entry
  # and `timeout:` the options.
  defp define(code, principal, opts \\ []) do
    entry = %{code: code, replace: Keyword.get(opts, :replace, false)}
    Define.run([entry], principal, Keyword.take(opts, [:timeout]))
  end

  defp run_error(code, principal, opts \\ []) do
    assert {:error, message} = define(code, principal, opts)
    message
  end

  defp lib_path(ns, file), do: "lib/#{Macro.underscore(ns)}/#{file}"

  defp stored(data_dir, ns, file),
    do: File.read!(Path.join(data_dir, "code/#{lib_path(ns, file)}"))

  test "defines a module and returns the summary", %{principal: principal} do
    ns = unique_namespace()
    mod = Module.concat([ns, Greeter])
    purge_on_exit([mod])

    code = """
    defmodule #{ns}.Greeter do
      @moduledoc "Greets people."

      @doc "Greets by name."
      def hello(name), do: "hello \#{name}"
    end
    """

    assert {:ok, "Defined #{ns}.Greeter (new)"} == define(code, principal)
    assert apply(mod, :hello, ["world"]) == "hello world"
  end

  describe "entries" do
    test "several entries land together, in order", %{principal: principal} do
      ns = unique_namespace()
      math = Module.concat([ns, Math])
      twice = Module.concat([ns, Twice])
      purge_on_exit([math, twice])

      entries = [
        %{
          code: """
          defmodule #{ns}.Math do
            @moduledoc "Math helpers."

            @doc "Doubles a number."
            def double(x), do: x * 2
          end
          """
        },
        %{
          code: """
          defmodule #{ns}.Twice do
            @moduledoc "Doubles twice."

            @doc "Quadruples a number."
            def go(x), do: x |> #{ns}.Math.double() |> #{ns}.Math.double()
          end
          """
        }
      ]

      assert {:ok, "Defined #{ns}.Math (new)\nDefined #{ns}.Twice (new)"} ==
               Define.run(entries, principal)

      assert apply(twice, :go, [2]) == 8
    end

    test "an entry with two modules is refused", %{principal: principal} do
      ns = unique_namespace()

      message =
        run_error(
          """
          defmodule #{ns}.One do
            @moduledoc "One."
          end

          defmodule #{ns}.Two do
            @moduledoc "Two."
          end
          """,
          principal
        )

      assert message ==
               "entry 1 defines #{ns}.One, #{ns}.Two — one module per entry; give each its " <>
                 "own entry"

      refute loaded?(Module.concat([ns, One]))
    end

    test "an entry with no module is refused", %{principal: principal} do
      assert run_error("IO.puts(\"hi\")", principal) ==
               "entry 1 defines no module — each entry is one top-level defmodule; run " <>
                 "expressions with eval"
    end

    test "an entry without code is refused", %{principal: principal} do
      assert {:error, message} = Define.run([%{replace: true}], principal)
      assert message =~ "entry 1 has no code"
    end

    test "a module named by two entries is refused", %{principal: principal} do
      ns = unique_namespace()
      code = "defmodule #{ns}.Twin do\n  @moduledoc \"Twin.\"\nend\n"

      assert {:error, message} = Define.run([%{code: code}, %{code: code}], principal)
      assert message == "#{ns}.Twin is defined by entries 1 and 2 — one entry per module"
      refute loaded?(Module.concat([ns, Twin]))
    end

    test "errors from every entry come back together, in entry order", %{
      principal: principal
    } do
      ns = unique_namespace()

      entries = [
        %{code: "defmodule #{ns}.First do\n  @moduledoc \"First.\"\n  def go, do: :ok\nend\n"},
        %{
          code:
            "defmodule #{ns}.Second do\n  @moduledoc \"Second.\"\n  def go, do: File.cwd!()\nend\n"
        }
      ]

      assert {:error, message} = Define.run(entries, principal)
      [first, second | _rest] = String.split(message, "\n")
      assert first =~ "#{ns}.First.go/0 is missing @doc"
      assert second =~ "#{lib_path(ns, "second.ex")}:3: File.cwd!/0 — File is not permitted"
    end

    test "replace: true sits on the entry", %{principal: principal} do
      ns = unique_namespace()
      mod = Module.concat([ns, Counter])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Counter do
        @moduledoc "Counts."

        @doc "The count."
        def count, do: 1
      end
      """

      assert {:ok, _summary} = define(code, principal)
      assert run_error(code, principal) =~ "already exists"

      replacement = String.replace(code, "do: 1", "do: 2")

      assert {:ok, "Defined #{ns}.Counter (replaced)\n  - changed count/0"} ==
               define(replacement, principal, replace: true)

      assert apply(mod, :count, []) == 2
    end

    test "a mixed call refuses the unflagged collision and defines nothing", %{
      principal: principal
    } do
      ns = unique_namespace()
      existing = Module.concat([ns, Existing])
      fresh = Module.concat([ns, Fresh])
      purge_on_exit([existing, fresh])

      existing_code = "defmodule #{ns}.Existing do\n  @moduledoc \"Exists.\"\nend\n"
      fresh_code = "defmodule #{ns}.Fresh do\n  @moduledoc \"Fresh.\"\nend\n"

      assert {:ok, _summary} = define(existing_code, principal)

      assert {:error, message} =
               Define.run([%{code: existing_code}, %{code: fresh_code, replace: true}], principal)

      assert message =~ "#{ns}.Existing already exists"
      assert message =~ "set replace: true on its entry"
      refute loaded?(fresh)
      assert Code.defined() == [existing]
    end
  end

  describe "formatting" do
    test "source is stored as the formatter lays it out", %{
      principal: principal,
      data_dir: data_dir
    } do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, Messy])])

      code = """
      defmodule #{ns}.Messy do
        @moduledoc   "Messy."
        @doc "Adds."
        def   add(a,b),   do: a+b
      end
      """

      assert {:ok, _summary} = define(code, principal)

      {:ok, formatted} = Format.format(code)
      assert stored(data_dir, ns, "messy.ex") == formatted
      assert formatted =~ "  def add(a, b), do: a + b\n"
    end

    test "plug, attr and slot stay bare and ~H content is untouched", %{
      principal: principal,
      data_dir: data_dir
    } do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, Components]), Module.concat([ns, Pages])])

      components = """
      defmodule #{ns}.Components do
        @moduledoc "Components."
        use Host.Web, :html

        attr :name, :string, required: true
        slot :inner_block

        @doc "Greets."
        def greeting(assigns) do
          ~H\"\"\"
          <span   class="x">hello   {@name}</span>
          \"\"\"
        end
      end
      """

      pages = """
      defmodule #{ns}.Pages do
        @moduledoc "Pages."
        use Host.Web, :controller

        plug :tag

        def show(conn, _params), do: json(conn, %{ok: true})

        defp tag(conn, _opts), do: conn
      end
      """

      assert {:ok, _summary} = Define.run([%{code: components}, %{code: pages}], principal)

      stored_components = stored(data_dir, ns, "components.ex")
      assert stored_components =~ "\n  attr :name, :string, required: true\n"
      assert stored_components =~ "\n  slot :inner_block\n"
      assert stored_components =~ ~s|<span   class="x">hello   {@name}</span>|
      assert stored(data_dir, ns, "pages.ex") =~ "\n  plug :tag\n"
    end

    test "defining the stored text again changes nothing", %{
      principal: principal,
      data_dir: data_dir
    } do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, Stable])])

      code = """
      defmodule #{ns}.Stable do
        @moduledoc "Stable."
        @doc "Go."
        def go(x),do: {x,x}
      end
      """

      assert {:ok, _summary} = define(code, principal)
      first = stored(data_dir, ns, "stable.ex")

      assert {:ok, _summary} = define(first, principal, replace: true)
      assert stored(data_dir, ns, "stable.ex") == first
    end
  end

  describe "errors locate by the module's path" do
    test "a syntax error names the module's path and quotes the line", %{
      principal: principal
    } do
      ns = unique_namespace()
      message = run_error("defmodule #{ns}.Broken do\n  def a do\nend\n", principal)

      assert message =~ "#{lib_path(ns, "broken.ex")}:"
      assert message =~ "missing terminator"
    end

    test "a syntax error with no readable module names the entry", %{principal: principal} do
      message = run_error("def a do\n  :ok\n", principal)
      assert message =~ ~r/\Aentry 1, line \d+: missing terminator/
    end

    test "a scanner refusal locates by path and quotes the line", %{principal: principal} do
      ns = unique_namespace()

      message =
        run_error(
          """
          defmodule #{ns}.Sneaky do
            @moduledoc "Sneaky."

            @doc "Reads."
            def read(path), do: File.read!(path)
          end
          """,
          principal
        )

      assert message ==
               "#{lib_path(ns, "sneaky.ex")}:5: File.read!/1 — File is not permitted by your " <>
                 "policy — Host.File provides scoped file access\n" <>
                 "    def read(path), do: File.read!(path)"
    end

    # The scanner is the only gate: a denied call in a module body would
    # run at compile time, so the refusal must land before the server
    # ever compiles the module.
    test "a denied compile-time call is refused before anything runs", %{
      principal: principal,
      data_dir: data_dir
    } do
      ns = unique_namespace()
      target = Path.join(data_dir, "pwned")

      message =
        run_error(
          """
          defmodule #{ns}.Sneaky do
            @moduledoc "Runs code at compile time."
            File.mkdir_p!("#{target}")
          end
          """,
          principal
        )

      assert message =~ "File.mkdir_p!/1 — File is not permitted"
      refute File.exists?(target)
    end

    test "a compile error locates by path and quotes the line", %{
      principal: principal,
      data_dir: data_dir
    } do
      ns = unique_namespace()

      message =
        quiet(fn ->
          run_error(
            """
            defmodule #{ns}.Bad do
              @moduledoc "Bad."

              @doc "Broken."
              def broken, do: undefined_local()
            end
            """,
            principal
          )
        end)

      assert message =~
               ~r/\A#{Regex.escape(lib_path(ns, "bad.ex"))}:5: undefined function undefined_local\/0/

      assert message =~ "\n    def broken, do: undefined_local()"
      refute message =~ "cannot compile module"
      refute message =~ ".staging"
      refute File.exists?(Path.join(data_dir, "code/.staging"))
    end

    test "a two-entry call's compile error names the right module", %{principal: principal} do
      ns = unique_namespace()

      entries = [
        %{code: "defmodule #{ns}.Fine do\n  @moduledoc \"Fine.\"\nend\n"},
        %{
          code: """
          defmodule #{ns}.Bad do
            @moduledoc "Bad."
            @doc "Broken."
            def broken, do: undefined_local()
          end
          """
        }
      ]

      assert {:error, message} = quiet(fn -> Define.run(entries, principal) end)
      assert message =~ "#{lib_path(ns, "bad.ex")}:4: undefined function undefined_local/0"
      refute message =~ "fine.ex"
      refute loaded?(Module.concat([ns, Fine]))
    end
  end

  @tag policies: [macros: [rules: [allow_defmacro: true]]]
  test "a defmacro is refused under the default and lands under allow_defmacro", %{
    principal: principal
  } do
    ns = unique_namespace()
    mod = Module.concat([ns, Doubler])
    purge_on_exit([mod])

    code = """
    defmodule #{ns}.Doubler do
      @moduledoc "Doubles."

      @doc "Doubles at compile time."
      defmacro double(x) do
        quote do: unquote(x) * 2
      end
    end
    """

    assert run_error(code, principal) =~ "defmacro is not permitted by your policy"

    {:ok, token} = Tokens.create(name: "phone", policy: "macros")
    assert {:ok, "Defined #{ns}.Doubler (new)"} == define(code, principal(token))
    assert macro_exported?(mod, :double, 1)
  end

  test "defguard compiles under the default: guard bodies are language-restricted", %{
    principal: principal
  } do
    ns = unique_namespace()
    mod = Module.concat([ns, Guarded])
    purge_on_exit([mod])

    code = """
    defmodule #{ns}.Guarded do
      @moduledoc "Uses a guard."

      @doc "True for adults."
      defguard is_adult(age) when is_integer(age) and age >= 18

      @doc "Checks an age."
      def adult?(age) when is_adult(age), do: true
      def adult?(_age), do: false
    end
    """

    assert {:ok, _summary} = define(code, principal)
    assert apply(mod, :adult?, [21]) == true
    assert apply(mod, :adult?, [9]) == false
  end

  test "docs gate rejections come back as teaching errors", %{principal: principal} do
    ns = unique_namespace()

    message =
      run_error(
        """
        defmodule #{ns}.Undocumented do
          def go, do: :ok
        end
        """,
        principal
      )

    assert message =~ "#{ns}.Undocumented is missing @moduledoc"
  end

  test "a defined module is callable from eval and from another define", %{principal: principal} do
    ns = unique_namespace()
    math = Module.concat([ns, Math])
    twice = Module.concat([ns, Twice])
    purge_on_exit([math, twice])

    assert {:ok, _summary} =
             define(
               """
               defmodule #{ns}.Math do
                 @moduledoc "Math helpers."

                 @doc "Doubles a number."
                 def double(x), do: x * 2
               end
               """,
               principal
             )

    assert {:ok, "=> 42"} = Eval.run("#{ns}.Math.double(21)", principal)

    # Granted by existence, to every token.
    {:ok, token} = Tokens.create(name: "phone")

    assert {:ok, _summary} =
             define(
               """
               defmodule #{ns}.Twice do
                 @moduledoc "Doubles twice."

                 @doc "Quadruples a number."
                 def go(x), do: x |> #{ns}.Math.double() |> #{ns}.Math.double()
               end
               """,
               principal(token)
             )

    assert {:ok, "=> 8"} = Eval.run("#{ns}.Twice.go(2)", principal(token))
  end

  test "the timeout rides the options", %{principal: principal} do
    ns = unique_namespace()

    message =
      run_error(
        """
        defmodule #{ns}.Slow do
          @moduledoc "Slow to compile."
          Enum.each(1..5_000_000_000, fn _ -> :ok end)
        end
        """,
        principal,
        timeout: 50
      )

    assert message =~ "define timed out after 50ms"
  end

  describe "scattered clauses" do
    test "a function whose clauses are separated is refused with nothing defined", %{
      principal: principal,
      data_dir: data_dir
    } do
      ns = unique_namespace()
      mod = Module.concat([ns, Scattered])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Scattered do
        @moduledoc "Scattered."

        @doc "Sizes."
        def size(:small), do: 1

        @doc "Names."
        def name, do: "x"

        def size(:large), do: 3
      end
      """

      message = quiet(fn -> run_error(code, principal) end)
      path = lib_path(ns, "scattered.ex")

      assert message ==
               "def size/1 (#{path}:10) is separated from its earlier clause (#{path}:5) " <>
                 "by other definitions — group the clauses of a function together"

      refute loaded?(mod)
      refute File.exists?(Path.join(data_dir, "code/#{path}"))
    end

    test "every scattered function gets a line, in source order", %{principal: principal} do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, Scattered])])

      code = """
      defmodule #{ns}.Scattered do
        @moduledoc "Scattered twice."

        @doc "Sizes."
        def size(:small), do: 1

        defp helper(1), do: :one

        def size(:large), do: 3

        defp helper(2), do: :two

        @doc "Uses the helper."
        def use_helper, do: {helper(1), helper(2)}
      end
      """

      message = quiet(fn -> run_error(code, principal) end)
      path = lib_path(ns, "scattered.ex")

      assert message ==
               "def size/1 (#{path}:9) is separated from its earlier clause (#{path}:5) " <>
                 "by other definitions — group the clauses of a function together\n" <>
                 "defp helper/1 (#{path}:11) is separated from its earlier clause (#{path}:7) " <>
                 "by other definitions — group the clauses of a function together"
    end

    test "the same name at another arity may sit apart", %{principal: principal} do
      ns = unique_namespace()
      mod = Module.concat([ns, Arities])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Arities do
        @moduledoc "Two arities of one name."

        @doc "One."
        def size(a), do: a

        @doc "Names."
        def name, do: "x"

        @doc "Two."
        def size(a, b), do: a + b
      end
      """

      assert {:ok, "Defined #{ns}.Arities (new)"} == define(code, principal)
      assert apply(mod, :size, [1, 2]) == 3
    end

    test "a scattered replace rolls the module back", %{principal: principal, data_dir: data_dir} do
      ns = unique_namespace()
      mod = Module.concat([ns, Counter])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Counter do
        @moduledoc "Counts."

        @doc "The count."
        def count(:a), do: 1
      end
      """

      assert {:ok, _summary} = define(code, principal)
      source = stored(data_dir, ns, "counter.ex")

      scattered = """
      defmodule #{ns}.Counter do
        @moduledoc "Counts."

        @doc "The count."
        def count(:a), do: 2

        @doc "Names."
        def name, do: "x"

        def count(:b), do: 3
      end
      """

      message = quiet(fn -> run_error(scattered, principal, replace: true) end)
      path = lib_path(ns, "counter.ex")

      assert message =~
               "def count/1 (#{path}:10) is separated from its earlier clause (#{path}:5)"

      assert apply(mod, :count, [:a]) == 1
      refute function_exported?(mod, :name, 0)
      assert stored(data_dir, ns, "counter.ex") == source
    end
  end
end
