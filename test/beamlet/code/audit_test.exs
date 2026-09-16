defmodule Beamlet.Code.AuditTest do
  # Loaded modules and the compiler tracer option are VM-global.
  use Beamlet.Case, async: false

  alias Beamlet.Code
  alias Beamlet.Code.Audit
  alias Beamlet.Principal

  setup %{token: token, data_dir: data_dir} do
    %{principal: principal(token), code_dir: Path.join(data_dir, "code")}
  end

  defp restart_code_server do
    :ok = Supervisor.terminate_child(Beamlet, Code)
    {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)
  end

  defp commit_count(dir) do
    dir |> git!(["rev-list", "--count", "HEAD"]) |> String.trim() |> String.to_integer()
  end

  defp last_message(dir), do: git!(dir, ["log", "-1", "--format=%B"])

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  describe "boot" do
    test "initializes the repo and commits an initial snapshot of what it finds", ctx do
      assert File.dir?(Path.join(ctx.code_dir, ".git"))
      assert File.read!(Path.join(ctx.code_dir, ".gitignore")) == "/ebin/\n/.staging/\n"
      assert commit_count(ctx.code_dir) == 1
      assert last_message(ctx.code_dir) =~ "initial snapshot"
      assert {:ok, system} = Principal.from_trailers(last_message(ctx.code_dir))
      assert system == Principal.system()

      files = git!(ctx.code_dir, ["ls-files"])
      assert files == ".gitignore\n"
    end

    test "a clean tree boots without a new commit", ctx do
      restart_code_server()
      assert commit_count(ctx.code_dir) == 1
    end

    test "a dirty tree is swept as manual changes under the system principal", ctx do
      ns = unique_namespace()
      purge_on_exit([Module.concat([ns, HandEdit])])

      File.write!(Path.join(ctx.code_dir, "lib/hand_edit.ex"), """
      defmodule #{ns}.HandEdit do
        @moduledoc "Edited while the beamlet was down."
      end
      """)

      restart_code_server()

      assert commit_count(ctx.code_dir) == 2
      message = last_message(ctx.code_dir)
      assert message =~ "manual changes"
      assert message =~ "User: beamlet (0)"

      assert git!(ctx.code_dir, ["log", "-1", "--format=%an <%ae>"]) =~
               "beamlet <beamlet@beamlet>"

      assert git!(ctx.code_dir, ["ls-files"]) =~ "lib/hand_edit.ex"
    end
  end

  describe "a define" do
    test "commits the modules in the subject and the principal as author and trailers", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Audited])
      purge_on_exit([mod])

      code = """
      defmodule #{ns}.Audited do
        @moduledoc "Exists to be committed."

        @doc "Returns :ok."
        def run, do: :ok
      end
      """

      assert {:ok, _summary} = Code.define(code, [mod], false, ctx.principal)

      assert commit_count(ctx.code_dir) == 2
      message = last_message(ctx.code_dir)
      assert message =~ "define: #{ns}.Audited (new)"
      assert message =~ "User: alice (#{ctx.principal.user_id})"
      assert message =~ "Token: test (#{ctx.principal.token_id})"
      assert message =~ "Policy: default"

      assert git!(ctx.code_dir, ["log", "-1", "--format=%an <%ae>"]) =~ "alice <alice@beamlet>"

      assert git!(ctx.code_dir, ["log", "-1", "--format=%cn <%ce>"]) =~
               "beamlet <beamlet@beamlet>"

      files = git!(ctx.code_dir, ["ls-files"])
      assert files =~ "lib/#{Macro.underscore(ns)}/audited.ex"
      refute files =~ ".beam"
    end

    test "round-trips the principal through the commit", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, RoundTrip])
      purge_on_exit([mod])

      assert {:ok, _summary} =
               Code.define(
                 "defmodule #{ns}.RoundTrip do\n  @moduledoc \"Round trip.\"\nend\n",
                 [mod],
                 false,
                 ctx.principal
               )

      assert {:ok, decoded} = Principal.from_trailers(last_message(ctx.code_dir))
      assert decoded == ctx.principal
    end

    test "git can filter the history by a trailer", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Filtered])
      purge_on_exit([mod])

      assert {:ok, _summary} =
               Code.define(
                 "defmodule #{ns}.Filtered do\n  @moduledoc \"Filtered.\"\nend\n",
                 [mod],
                 false,
                 ctx.principal
               )

      subjects = git!(ctx.code_dir, ["log", "--format=%s", "--grep=^Token: test", "--all"])
      assert subjects == "define: #{ns}.Filtered (new)\n"
    end

    test "flags replaced modules in the subject", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Twice])
      purge_on_exit([mod])
      code = "defmodule #{ns}.Twice do\n  @moduledoc \"Twice.\"\nend\n"

      assert {:ok, _summary} = Code.define(code, [mod], false, ctx.principal)
      assert {:ok, _summary} = Code.define(code, [mod], true, ctx.principal)

      assert last_message(ctx.code_dir) =~ "define: #{ns}.Twice (replaced)"
    end
  end

  describe "a remove" do
    test "commits the modules in the subject with the same provenance", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, Gone])
      purge_on_exit([mod])

      assert {:ok, _summary} =
               Code.define(
                 "defmodule #{ns}.Gone do\n  @moduledoc \"Gone soon.\"\nend\n",
                 [mod],
                 false,
                 ctx.principal
               )

      assert :ok = Code.remove([mod], ctx.principal)

      message = last_message(ctx.code_dir)
      assert message =~ "remove: #{ns}.Gone"
      assert {:ok, decoded} = Principal.from_trailers(message)
      assert decoded == ctx.principal
      refute git!(ctx.code_dir, ["ls-files"]) =~ "gone.ex"
    end
  end

  describe "without git" do
    setup do
      previous_path = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", previous_path) end)
      empty = Path.join(System.tmp_dir!(), "beamlet_no_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      System.put_env("PATH", empty)
      :ok
    end

    test "check!/0 raises a teaching error" do
      assert_raise RuntimeError, ~r/git was not found on PATH.*install git/, &Audit.check!/0
    end

    @tag :capture_log
    test "the code server does not start" do
      :ok = Supervisor.terminate_child(Beamlet, Code)

      assert {:error, {%RuntimeError{message: message}, _stack}} =
               Supervisor.restart_child(Beamlet, Code)

      assert message =~ "git was not found on PATH"
    end
  end
end
