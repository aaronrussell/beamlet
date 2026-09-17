defmodule Beamlet.Code.CompileArtifactTest do
  # Loaded modules and the compiler options are VM-global.
  use Beamlet.Case, async: false

  alias Beamlet.Code

  setup do
    %{ns: unique_namespace()}
  end

  test "compiles source and loads the modules", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    source = "defmodule #{ns}.Artifact do\n  def answer, do: 42\nend\n"

    assert {:ok, [^mod]} = Code.compile_artifact(source, "artifact.ex")
    assert mod.answer() == 42
    refute mod in Code.defined()
  end

  test "recompiling the same name hot-swaps without conflict", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    v1 = "defmodule #{ns}.Artifact do\n  def version, do: 1\nend\n"
    v2 = "defmodule #{ns}.Artifact do\n  def version, do: 2\nend\n"

    assert {:ok, [^mod]} = Code.compile_artifact(v1, "artifact.ex")
    assert {:ok, [^mod]} = Code.compile_artifact(v2, "artifact.ex")
    assert mod.version() == 2
  end

  test "a compile error returns the message and leaves the loaded version serving", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    good = "defmodule #{ns}.Artifact do\n  def version, do: 1\nend\n"
    bad = "defmodule #{ns}.Artifact do\n  def version, do:\nend\n"

    assert {:ok, [^mod]} = Code.compile_artifact(good, "artifact.ex")
    assert {:error, message} = quiet(fn -> Code.compile_artifact(bad, "artifact.ex") end)

    assert message =~ "syntax error" or message =~ "unexpected"
    assert mod.version() == 1
  end

  test "compiler globals are restored after success and failure", %{ns: ns} do
    purge_on_exit([Module.concat([ns, "Artifact"])])
    docs = Elixir.Code.get_compiler_option(:docs)
    conflict = Elixir.Code.get_compiler_option(:ignore_module_conflict)
    tracers = Elixir.Code.get_compiler_option(:tracers)

    source = "defmodule #{ns}.Artifact do\n  def answer, do: 42\nend\n"
    assert {:ok, _modules} = Code.compile_artifact(source, "artifact.ex")
    assert {:error, _message} = quiet(fn -> Code.compile_artifact("%{", "artifact.ex") end)

    assert Elixir.Code.get_compiler_option(:docs) == docs
    assert Elixir.Code.get_compiler_option(:ignore_module_conflict) == conflict
    assert Elixir.Code.get_compiler_option(:tracers) == tracers
  end
end
