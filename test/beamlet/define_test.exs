defmodule Beamlet.DefineTest do
  # Loaded modules and the compiler tracer option are VM-global.
  use Beamlet.Case, async: false

  alias Beamlet.Define
  alias Beamlet.Eval
  alias Beamlet.Users

  setup %{token: token} do
    %{principal: principal(token)}
  end

  defp run_error(code, principal, opts \\ []) do
    assert {:error, message} = Define.run(code, principal, opts)
    message
  end

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

    assert {:ok, "Defined #{ns}.Greeter (new)"} == Define.run(code, principal)
    assert apply(mod, :hello, ["world"]) == "hello world"
  end

  test "scanner rejections come back as teaching errors", %{principal: principal} do
    assert run_error("IO.puts(\"hi\")", principal) =~
             "define declares modules — run expressions with eval"
  end

  test "policy violations inside bodies come back as teaching errors", %{principal: principal} do
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

    assert message =~ "File.read!/1 — File is not permitted"
  end

  # The scanner is the only gate: a denied call in a module body would
  # run at compile time, so the refusal must land before the server
  # ever compiles the buffer.
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

  @tag policies: [macros: [rules: [allow_defmacro: true]]]
  test "a defmacro is refused under the default and lands under allow_defmacro", %{
    principal: principal,
    user: user
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

    {:ok, token} = Users.create_token(user, name: "phone", policy: "macros")
    assert {:ok, "Defined #{ns}.Doubler (new)"} == Define.run(code, principal(token))
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

    assert {:ok, _summary} = Define.run(code, principal)
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

  test "replace: true rides the options", %{principal: principal} do
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

    assert {:ok, _summary} = Define.run(code, principal)
    assert run_error(code, principal) =~ "already exists"

    replacement = String.replace(code, "do: 1", "do: 2")

    assert {:ok, "Defined #{ns}.Counter (replaced)"} ==
             Define.run(replacement, principal, replace: true)

    assert apply(mod, :count, []) == 2
  end

  test "a defined module is callable from eval and from another define", %{
    principal: principal,
    user: user
  } do
    ns = unique_namespace()
    math = Module.concat([ns, Math])
    twice = Module.concat([ns, Twice])
    purge_on_exit([math, twice])

    assert {:ok, _summary} =
             Define.run(
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
    {:ok, token} = Users.create_token(user, name: "phone")

    assert {:ok, _summary} =
             Define.run(
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
end
