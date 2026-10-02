defmodule Beamlet.Code.CompileArtifactTest do
  use Beamlet.Case

  alias Beamlet.Code

  setup do
    %{ns: unique_namespace()}
  end

  defp quoted(source), do: Elixir.Code.string_to_quoted!(source)

  test "compiles quoted form and loads the modules", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    source = quoted("defmodule #{ns}.Artifact do\n  def answer, do: 42\nend\n")

    assert {:ok, [^mod]} = Code.compile_artifact(fn -> source end, "artifact.ex")
    assert mod.answer() == 42
    refute mod in Code.defined()
  end

  test "recompiling the same name hot-swaps without conflict", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    v1 = quoted("defmodule #{ns}.Artifact do\n  def version, do: 1\nend\n")
    v2 = quoted("defmodule #{ns}.Artifact do\n  def version, do: 2\nend\n")

    assert {:ok, [^mod]} = Code.compile_artifact(fn -> v1 end, "artifact.ex")
    assert {:ok, [^mod]} = Code.compile_artifact(fn -> v2 end, "artifact.ex")
    assert mod.version() == 2
  end

  test "a compile error returns the message and puts the last good version back", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    good = quoted("defmodule #{ns}.Artifact do\n  def version, do: 1\nend\n")
    bad = quoted("defmodule #{ns}.Artifact do\n  def version, do: 2\n  raise \"boom\"\nend\n")

    assert {:ok, [^mod]} = Code.compile_artifact(fn -> good end, "artifact.ex")
    assert {:error, "boom"} = quiet(fn -> Code.compile_artifact(fn -> bad end, "artifact.ex") end)

    assert mod.version() == 1
  end

  test "a source that raises returns the message and the last good version keeps serving",
       %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    good = quoted("defmodule #{ns}.Artifact do\n  def version, do: 1\nend\n")

    assert {:ok, [^mod]} = Code.compile_artifact(fn -> good end, "artifact.ex")
    assert {:error, "no table"} = Code.compile_artifact(fn -> raise "no table" end, "artifact.ex")

    assert mod.version() == 1
    assert {:ok, [^mod]} = Code.compile_artifact(fn -> good end, "artifact.ex")
  end

  test "a first compile that fails leaves nothing loaded", %{ns: ns} do
    mod = Module.concat([ns, "Artifact"])
    purge_on_exit([mod])

    bad = quoted("defmodule #{ns}.Artifact do\n  raise \"boom\"\nend\n")

    assert {:error, "boom"} = quiet(fn -> Code.compile_artifact(fn -> bad end, "artifact.ex") end)
    refute loaded?(mod)
  end

  test "a compile whose caller died while it was queued never runs", %{ns: ns} do
    first = Module.concat([ns, "First"])
    queued = Module.concat([ns, "Queued"])
    purge_on_exit([first, queued])

    test = self()
    first_source = quoted("defmodule #{ns}.First do\nend\n")
    queued_source = quoted("defmodule #{ns}.Queued do\nend\n")

    holding = fn ->
      send(test, {:holding, self()})
      receive do: (:go -> first_source)
    end

    spawn(fn -> send(test, {:first, Code.compile_artifact(holding, "first.ex")}) end)
    assert_receive {:holding, server}, 5_000

    # Tracing the server's receives shows the compile queued behind
    # the first before its caller is killed.
    :erlang.trace(server, true, [:receive])
    caller = spawn(fn -> Code.compile_artifact(fn -> queued_source end, "queued.ex") end)

    assert_receive {:trace, ^server, :receive,
                    {:"$gen_call", _from, {:compile_artifact, _source, "queued.ex"}}},
                   5_000

    :erlang.trace(server, false, [:receive])
    caller_ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

    send(server, :go)
    assert_receive {:first, {:ok, [^first]}}, 5_000
    :sys.get_state(Code)

    refute loaded?(queued)
  end

  test "compiler globals are restored after success and failure", %{ns: ns} do
    purge_on_exit([Module.concat([ns, "Artifact"])])
    docs = Elixir.Code.get_compiler_option(:docs)
    conflict = Elixir.Code.get_compiler_option(:ignore_module_conflict)
    tracers = Elixir.Code.get_compiler_option(:tracers)

    source = quoted("defmodule #{ns}.Artifact do\n  def answer, do: 42\nend\n")
    bad = quoted("defmodule #{ns}.Artifact do\n  raise \"boom\"\nend\n")
    assert {:ok, _modules} = Code.compile_artifact(fn -> source end, "artifact.ex")

    assert {:error, _message} =
             quiet(fn -> Code.compile_artifact(fn -> bad end, "artifact.ex") end)

    assert Elixir.Code.get_compiler_option(:docs) == docs
    assert Elixir.Code.get_compiler_option(:ignore_module_conflict) == conflict
    assert Elixir.Code.get_compiler_option(:tracers) == tracers
  end
end
