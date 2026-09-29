defmodule Beamlet.Code.CompileArtifactTest do
  # Loaded modules and the compiler options are VM-global.
  use Beamlet.Case, async: false

  alias Beamlet.Code

  setup do
    %{ns: unique_namespace()}
  end

  defp quoted(source), do: Elixir.Code.string_to_quoted!(source)

  test "compiles quoted form and loads the modules", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    source = quoted("defmodule #{ns}.Artifact do\n  def answer, do: 42\nend\n")

    assert {:ok, [^mod]} = Code.compile_artifact(source, "artifact.ex")
    assert mod.answer() == 42
    refute mod in Code.defined()
  end

  test "recompiling the same name hot-swaps without conflict", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    v1 = quoted("defmodule #{ns}.Artifact do\n  def version, do: 1\nend\n")
    v2 = quoted("defmodule #{ns}.Artifact do\n  def version, do: 2\nend\n")

    assert {:ok, [^mod]} = Code.compile_artifact(v1, "artifact.ex")
    assert {:ok, [^mod]} = Code.compile_artifact(v2, "artifact.ex")
    assert mod.version() == 2
  end

  test "a compile error returns the message and puts the last good version back", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    good = quoted("defmodule #{ns}.Artifact do\n  def version, do: 1\nend\n")
    bad = quoted("defmodule #{ns}.Artifact do\n  def version, do: 2\n  raise \"boom\"\nend\n")

    assert {:ok, [^mod]} = Code.compile_artifact(good, "artifact.ex")
    assert {:error, "boom"} = quiet(fn -> Code.compile_artifact(bad, "artifact.ex") end)

    assert mod.version() == 1
  end

  test "a first compile that fails leaves nothing loaded", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    bad = quoted("defmodule #{ns}.Artifact do\n  raise \"boom\"\nend\n")

    assert {:error, "boom"} = quiet(fn -> Code.compile_artifact(bad, "artifact.ex") end)
    refute loaded?(mod)
  end

  test "compiler globals are restored after success and failure", %{ns: ns} do
    purge_on_exit([Module.concat([ns, "Artifact"])])
    docs = Elixir.Code.get_compiler_option(:docs)
    conflict = Elixir.Code.get_compiler_option(:ignore_module_conflict)
    tracers = Elixir.Code.get_compiler_option(:tracers)

    source = quoted("defmodule #{ns}.Artifact do\n  def answer, do: 42\nend\n")
    bad = quoted("defmodule #{ns}.Artifact do\n  raise \"boom\"\nend\n")
    assert {:ok, _modules} = Code.compile_artifact(source, "artifact.ex")
    assert {:error, _message} = quiet(fn -> Code.compile_artifact(bad, "artifact.ex") end)

    assert Elixir.Code.get_compiler_option(:docs) == docs
    assert Elixir.Code.get_compiler_option(:ignore_module_conflict) == conflict
    assert Elixir.Code.get_compiler_option(:tracers) == tracers
  end
end
