defmodule Host.CodeTest do
  # Loaded modules and the compiler tracer option are VM-global.
  use Beamlet.Case, async: false

  alias Beamlet.Code
  alias Beamlet.Define
  alias Beamlet.Eval
  alias Beamlet.Principal

  setup %{token: token} do
    %{principal: principal(token)}
  end

  defp define_note!(principal) do
    ns = unique_namespace()
    mod = Module.concat([ns, Note])
    purge_on_exit([mod])

    {:ok, _summary} =
      Define.run(
        """
        defmodule #{ns}.Note do
          @moduledoc "A note to self."

          @doc "The note."
          def text, do: "remember"
        end
        """,
        principal
      )

    {ns, mod}
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  describe "through eval" do
    test "print_modules prints the listing and returns :ok", ctx do
      {ns, _mod} = define_note!(ctx.principal)

      assert {:ok, result} = Eval.run("Host.Code.print_modules()", ctx.principal)

      assert result =~ "Defined modules (define):\n  #{ns}.Note — A note to self."
      assert result =~ "Host modules (your beamlet's stdlib):"
      assert result =~ ~r/^  Host\.Code — /m
      assert result =~ ~r/^  Host\.PubSub — /m
      assert String.ends_with?(result, "=> :ok")
    end

    test "print_policy renders the token's policy", ctx do
      assert {:ok, result} = Eval.run("Host.Code.print_policy()", ctx.principal)

      assert result =~ "Policy: default\nTools: define, eval"
      assert result =~ "Not available:"
      assert result =~ "Partially granted:"
      assert result =~ "defmacro/defmacrop are not permitted in define"
      assert String.ends_with?(result, "=> :ok")
    end

    @tag policies: [relaxed: [rules: [allow_defmacro: true]]]
    test "print_policy renders the policy the token names, not the default", %{user: user} do
      {:ok, token} = Beamlet.Users.create_token(user, name: "phone", policy: "relaxed")

      assert {:ok, result} = Eval.run("Host.Code.print_policy()", principal(token))

      assert result =~ "Policy: relaxed"
      assert result =~ "call targets must be literal modules"
      refute result =~ "defmacro/defmacrop"
    end

    test "print_docs and print_source serve a defined module", ctx do
      {ns, _mod} = define_note!(ctx.principal)

      assert {:ok, result} =
               Eval.run(
                 "Host.Code.print_docs(#{ns}.Note)\nHost.Code.print_source(#{ns}.Note)",
                 ctx.principal
               )

      assert result =~ "# #{ns}.Note\n\nA note to self."
      assert result =~ ~r/^  text\(\) — The note\./m
      assert result =~ "defmodule #{ns}.Note do"
    end

    test "a denied module raises the teaching copy as an eval error", ctx do
      assert {:error, error} = Eval.run("Host.Code.print_docs(Phoenix.PubSub)", ctx.principal)

      assert error =~
               "** (RuntimeError) Phoenix.PubSub is not permitted by your policy — " <>
                 "publish/subscribe goes through Host.PubSub"
    end

    test "output printed before a failure survives it", ctx do
      assert {:error, error} =
               Eval.run(
                 "Host.Code.print_docs(Enum)\nHost.Code.print_docs(Phoenix.PubSub)",
                 ctx.principal
               )

      assert error =~ "# Enum"
      assert error =~ "Phoenix.PubSub is not permitted by your policy"
    end

    test "remove unloads the module and commits as the token", ctx do
      {ns, mod} = define_note!(ctx.principal)

      assert {:ok, "=> :ok"} = Eval.run("Host.Code.remove(#{ns}.Note)", ctx.principal)

      refute loaded?(mod)
      assert Code.defined() == []

      message = git!(Path.join(ctx.data_dir, "code"), ["log", "-1", "--format=%B"])
      assert message =~ "remove: #{ns}.Note"
      assert {:ok, decoded} = Principal.from_trailers(message)
      assert decoded == ctx.principal
    end

    test "remove refuses a beamlet module and a bad argument", ctx do
      assert {:error, error} = Eval.run("Host.Code.remove(Enum)", ctx.principal)

      assert error =~
               "Host.Code.remove removes defined modules only — Enum is part of your beamlet."

      assert {:error, error} = Eval.run(~s|Host.Code.remove(["Enum"])|, ctx.principal)
      assert error =~ "Host.Code.remove takes a module or a list of modules"
    end
  end

  describe "the ambient principal" do
    test "each function raises without one" do
      for call <- [
            &Host.Code.print_modules/0,
            &Host.Code.print_policy/0,
            fn -> Host.Code.print_docs(Enum) end,
            fn -> Host.Code.print_source(Enum) end,
            fn -> Host.Code.remove(Enum) end
          ] do
        assert_raise RuntimeError,
                     ~r/^Host\.Code\.\w+ works from eval, where your code acts as you/,
                     call
      end
    end

    test "act_as/1 stands in for eval's runtime", %{token: token} do
      act_as(token)

      output = ExUnit.CaptureIO.capture_io(fn -> assert :ok = Host.Code.print_modules() end)
      assert output =~ "Host modules (your beamlet's stdlib):"
    end
  end
end
