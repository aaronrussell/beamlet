defmodule Beamlet.EvalTest do
  use Beamlet.Case

  alias Beamlet.Eval
  alias Beamlet.Principal
  alias Beamlet.Users

  setup %{token: token} do
    %{principal: principal(token)}
  end

  defp principal(token) do
    {:ok, authenticated} = Users.authenticate(token.secret)
    Principal.from_token(authenticated)
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

  describe "the dispatch rule" do
    test "a variable call target is refused under the default policy", %{principal: principal} do
      assert run_error("mod = Enum\nmod.count([1])", principal) =~
               "call target must be a literal module"
    end

    @tag policies: [relaxed: [rules: [allow_dynamic_dispatch: true]]]
    test "a variable call target evaluates under a policy that allows it", %{user: user} do
      {:ok, token} = Users.create_token(user, name: "phone", policy: "relaxed")

      assert {:ok, "=> 1"} = Eval.run("mod = Enum\nmod.count([1])", principal(token))
    end
  end

  describe "the principal" do
    @tag policies: [probe: [allow: [Beamlet.Principal]]]
    test "is what the evaluated code runs as", %{user: user} do
      {:ok, token} = Users.create_token(user, name: "phone", policy: "probe")

      assert {:ok, ~s|=> "alice"|} =
               Eval.run("Beamlet.Principal.current().user_name", principal(token))
    end
  end
end
