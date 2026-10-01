defmodule Beamlet.EvalTest do
  use Beamlet.Case

  alias Beamlet.Eval
  alias Beamlet.Tokens

  setup %{token: token} do
    %{principal: principal(token)}
  end

  defp run_error(code, principal, opts \\ []) do
    assert {:error, message} = Eval.run(code, principal, opts)
    message
  end

  describe "the result" do
    test "is the inspected last expression", %{principal: principal} do
      assert {:ok, "=> 2"} = Eval.run("1 + 1", principal)
    end

    test "carries what was printed before it", %{principal: principal} do
      assert {:ok, "hi\n\n=> :ok"} = Eval.run(~s|IO.puts("hi")|, principal)
    end

    test "captures IO.inspect", %{principal: principal} do
      assert {:ok, "[1, 2, 3]\n\n=> :done"} = Eval.run("IO.inspect([1, 2, 3])\n:done", principal)
    end

    test "bounds the inspected value", %{principal: principal} do
      assert {:ok, output} = Eval.run("Enum.to_list(1..100)", principal)
      assert output =~ "..."
      refute output =~ "100"
    end

    test "is cut at max_output with a line saying how much was shown", %{principal: principal} do
      assert {:ok, output} =
               Eval.run(~s|IO.puts(String.duplicate("x", 500))|, principal, max_output: 100)

      assert output =~ "...(truncated, showing first 100B of 5"
      assert byte_size(output) < 250
    end

    test "never cuts through a character", %{principal: principal} do
      assert {:ok, output} =
               Eval.run(~s|IO.puts(String.duplicate("é", 100))|, principal, max_output: 101)

      assert String.valid?(output)
      assert output =~ "showing first 101B"
    end
  end

  describe "errors" do
    test "a refused call carries the policy's teaching copy", %{principal: principal} do
      message = run_error(~s|File.read!("/etc/passwd")|, principal)

      assert message =~ "File.read!/1"
      assert message =~ "not permitted by your policy"
      assert message =~ "Host.File provides scoped file access"
    end

    test "an exception is formatted after the output before it", %{principal: principal} do
      message = run_error(~s|IO.puts("before")\nraise "boom"|, principal)

      assert message =~ "before"
      assert message =~ "(RuntimeError) boom"
    end

    test "a timeout keeps the output before it and names the limit", %{principal: principal} do
      message =
        run_error(
          ~s|IO.puts("start")\nStream.cycle([1]) \|> Enum.each(fn _ -> :ok end)|,
          principal,
          timeout: 100
        )

      assert message =~ "start"
      assert message =~ "Evaluation timed out after 100ms"
    end

    test "runaway memory is stopped", %{principal: principal} do
      message =
        run_error("length(Enum.to_list(1..50_000_000))", principal, max_heap_bytes: 1_000_000)

      assert message =~ "went over the memory limit of 976.6KB"
    end

    test "a throw is formatted", %{principal: principal} do
      assert run_error("throw :ball", principal) =~ "** (throw) :ball"
    end

    test "a compile error carries the diagnostic, not 'errors have been logged'", %{
      principal: principal
    } do
      message = run_error("Events |> order_by(desc: :x) |> limit(3)", principal)

      assert message =~ "(CompileError) line 1: undefined function limit/2"
      refute message =~ "errors have been logged"
    end
  end

  describe "stack traces" do
    # The beam records the staging file after a define and the stored
    # file after a boot; the frame reads the same either way.
    test "a defined module's frames locate by its stored path and line", %{
      principal: principal
    } do
      ns = unique_namespace()
      mod = Module.concat([ns, Boom])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Boom do
        @moduledoc "Raises."

        @doc "Raises with the argument."
        def go(x) do
          y = x + 1
          raise "boom \#{y}"
        end
      end
      """

      assert {:ok, _summary} = Beamlet.Define.run([%{code: code}], principal)

      path = "lib/#{Macro.underscore(ns)}/boom.ex"
      source_file = Beamlet.Code.manifest()[mod].source_file
      lines = source_file |> File.read!() |> String.split("\n")
      line = Enum.find_index(lines, &(&1 =~ "raise")) + 1

      message = run_error("#{ns}.Boom.go(1)", principal)
      assert message =~ "(RuntimeError) boom 2"
      assert message =~ "\n    #{path}:#{line}: #{ns}.Boom.go/1\n"
      refute message =~ ".staging"

      :ok = Supervisor.terminate_child(Beamlet, Beamlet.Code)
      :code.purge(mod)
      :code.delete(mod)
      {:ok, _pid} = Supervisor.restart_child(Beamlet, Beamlet.Code)

      message = run_error("#{ns}.Boom.go(1)", principal)
      assert message =~ "\n    #{path}:#{line}: #{ns}.Boom.go/1\n"
    end
  end

  describe "the dispatch rule" do
    test "a variable call target is refused under the default policy", %{principal: principal} do
      assert run_error("mod = Enum\nmod.count([1])", principal) =~
               "call target must be a literal module"
    end

    @tag policies: [relaxed: [rules: [allow_dynamic_dispatch: true]]]
    test "a variable call target evaluates under a policy that allows it" do
      {:ok, token} = Tokens.create(name: "phone", policy: "relaxed")

      assert {:ok, "=> 1"} = Eval.run("mod = Enum\nmod.count([1])", principal(token))
    end
  end

  describe "Host.File" do
    test "write and read round-trip through the shared root", %{principal: principal} do
      assert {:ok, "=> :ok"} = Eval.run(~s|Host.File.write!("notes.md", "hello")|, principal)
      assert {:ok, ~s|=> "hello"|} = Eval.run(~s|Host.File.read!("notes.md")|, principal)
    end

    test "a non-string path raises the teaching error", %{principal: principal} do
      assert run_error("Host.File.read(:notes)", principal) =~
               "Host.File paths are strings, got: :notes"
    end

    test "Path is granted but wildcard is not", %{principal: principal} do
      assert {:ok, ~s|=> "a/b"|} = Eval.run(~s|Path.join("a", "b")|, principal)
      assert run_error(~s|Path.wildcard("*")|, principal) =~ "Path.wildcard/1 is not permitted"
    end
  end

  describe "the principal" do
    @tag policies: [probe: [allow: [Beamlet.Principal]]]
    test "is what the evaluated code runs as" do
      {:ok, token} = Tokens.create(name: "phone", policy: "probe")

      assert {:ok, ~s|=> "phone"|} =
               Eval.run("Beamlet.Principal.current().token_label", principal(token))
    end
  end
end
