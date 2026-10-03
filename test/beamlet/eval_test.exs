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

      assert output =~ "...(output truncated, showing first 93B of 501B"
      assert String.ends_with?(output, "\n=> :ok")
      assert byte_size(output) < 250
    end

    test "never cuts through a character", %{principal: principal} do
      assert {:ok, output} =
               Eval.run(~s|IO.puts(String.duplicate("é", 100))|, principal, max_output: 102)

      assert String.valid?(output)
      assert output =~ "showing first 94B of 201B"
    end

    test "a print loop keeps the first max_output and counts the rest", %{principal: principal} do
      code = ~s|Enum.each(1..50, fn _ -> IO.puts(String.duplicate("x", 100_000)) end)|

      assert {:ok, output} = Eval.run(code, principal, max_output: 32_768)
      assert output =~ "...(output truncated, showing first 32KB of 4.8MB"
      assert String.ends_with?(output, "\n=> :ok")
      assert byte_size(output) < 33_000
    end

    # Every shape of output request reaches the device, not only the
    # one IO.puts makes: latin-1 bytes, an io_lib format the device
    # calls back, and chardata it cannot translate.
    @tag policies: [printer: [allow: [IO, :io]]]
    test "takes every kind of output request" do
      {:ok, token} = Tokens.create(name: "printer", policy: "printer")
      principal = principal(token)

      assert {:ok, "café\n\n=> :ok"} =
               Eval.run(~s|IO.binwrite(<<"caf", 0xE9, "\\n">>)|, principal)

      assert {:ok, "1 + 1 = 2\n\n=> :ok"} =
               Eval.run(~s|:io.format("~p + ~p = ~p~n", [1, 1, 2])|, principal)

      code = ~s|try do IO.write([:bad]) rescue ArgumentError -> IO.puts("still printing") end|
      assert {:ok, "still printing\n\n=> :ok"} = Eval.run(code, principal)
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

    test "an off-heap binary counts against the memory limit", %{principal: principal} do
      message =
        run_error(~s|byte_size(String.duplicate("x", 20_000_000))|, principal,
          max_heap_bytes: 10_000_000
        )

      assert message =~ "went over the memory limit of 9.5MB"
    end

    test "the error is kept whole and the output takes the room left", %{principal: principal} do
      code = ~s|IO.puts(String.duplicate("x", 500))\nraise "boom"|
      message = run_error(code, principal, max_output: 200)

      assert message =~ "...(output truncated, showing first"
      assert message =~ "(RuntimeError) boom"
    end

    test "a print loop that times out still names the limit", %{principal: principal} do
      code = ~s|Stream.cycle([1]) \|> Enum.each(fn _ -> IO.puts("tick") end)|
      message = run_error(code, principal, timeout: 50, max_output: 1_000)

      assert message =~ "...(output truncated, showing first"
      assert message =~ "Evaluation timed out after 50ms"
      assert byte_size(message) < 1_200
    end

    test "an error longer than max_output is cut and the output gives way", %{
      principal: principal
    } do
      code = ~s|IO.puts("before")\nraise String.duplicate("x", 500)|
      message = run_error(code, principal, max_output: 100)

      assert message =~ "...(output truncated, showing first 0B of 7B"
      assert message =~ "** (RuntimeError) xxx"
      assert message =~ "...(truncated, showing first 100B of"
      assert byte_size(message) < 300
    end

    test "an invalid byte in an error message is replaced", %{principal: principal} do
      message = run_error("raise <<255>>", principal)

      assert String.valid?(message)
      assert message =~ "(RuntimeError) \uFFFD"
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
