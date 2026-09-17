defmodule Beamlet.Code do
  @moduledoc """
  The code server: the modules defined on your beamlet, their sources
  and beams under the data dir, and the git history of both.

  Everything an agent defines lives under `<data_dir>/code`:

      code/
        lib/         one source file per module, shopping/list.ex for Shopping.List
        migrations/  one file per migration, 0001_shopping_create_lists.ex
        ebin/        the compiled beams, with docs, rebuilt from the sources at boot
        .git       the history: one commit per define or remove
        .staging   the buffer being compiled, gone when it is done

  The `define` tool and `Host.Code.remove` are calls into this
  process, so mutations serialize and two writers never race the
  code dir. A define is all-or-nothing: the buffer compiles into the
  VM first, and sources and beams are written only after every check
  has passed; a failed compile, a timeout, or a client cancelling the
  request rolls the VM back by reloading the previous beams, and
  nothing on disk has changed. The one accepted window is that
  compilation loads modules as it goes, so an eval running at the
  same moment can observe a half-loaded new version for a few
  milliseconds, and replacing a module an eval is still executing
  old code of will kill that eval.

  A module that uses `Ecto.Migration` is a migration: it is filed
  under `migrations/` with the next version number, one past both
  the files on disk and the versions the agent database records as
  applied, and stays editable until `Host.Migrator` applies it. An
  applied migration must be rolled back before it can be replaced or
  removed, so the applied stack and the files never disagree.

  Boot compiles the code dir, rebuilding the dependency map and the
  beams. A module that fails to compile, a bad hand edit or a
  beamlet upgrade, is quarantined: skipped, logged and held in the
  server's state, never taking the beamlet down. Boot compiles carry
  no policy gate: the scanner runs when code is submitted through the
  tools, and the code dir's contents were either scanned on the way
  in or hand-edited by the operator, who is trusted.

  The dependency map has two halves, both between defined modules.
  Compile-time edges, from structs, macros, imports and requires,
  drive replace's dependent recompiles. Runtime call records, caller
  to callee function and arity, drive remove's refusal and replace's
  check that a dropped function is not still called. A plain remote
  call resolves by name when it runs and is never stale, so it never
  triggers a recompile. The map blocks only provable breakage:
  removing a module something references, or replacing away a
  function something still calls.

  Git holds the history. Beamlet commits after every define and
  remove, with the user as the author (`alice <alice@beamlet>`) and
  the principal as trailers (`Beamlet.Principal.to_trailers/1`), and
  sweeps hand edits into a commit of their own at boot. Git is a
  requirement: a beamlet whose PATH has no git does not start.

  The defined set, the paths behind it and the quarantine are
  published to a table this process owns, so a lookup (`defined/0`,
  `manifest/0`, `quarantined/0`) never waits on a compile in progress.
  """

  use GenServer

  require Logger

  alias Beamlet.Code.Audit
  alias Beamlet.Code.Tracer
  alias Beamlet.Config
  alias Beamlet.Principal

  @typedoc "A quarantined source file: skipped at boot, kept on disk."
  @type quarantine_entry :: %{file: Path.t(), modules: [module()], error: String.t()}

  @doc """
  Starts the code server, loading the code dir.

  `code_dir:` overrides `Beamlet.Config.code_dir/0`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Defines the modules in `code` as `principal`: checks the names,
  compiles with the dependents of any replaced module, then persists
  and loads, all-or-nothing. `modules` is the list the scanner
  extracted from the buffer (`Beamlet.Scanner.scan_define/2`), and
  `replace?` permits redefining modules already defined.

  Returns the summary the agent reads, or a teaching error. The
  compile timeout comes from `config :beamlet, :define`;
  `opts[:timeout]` overrides it. The call itself allows twice that
  and a margin, since a define may wait behind another one.
  """
  @spec define(String.t(), [module()], boolean(), Principal.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def define(code, modules, replace?, %Principal{} = principal, opts \\ []) do
    timeout = Keyword.get_lazy(opts, :timeout, fn -> Config.define()[:timeout] end)

    GenServer.call(
      __MODULE__,
      {:define, code, modules, replace?, principal, timeout},
      2 * timeout + 5_000
    )
  end

  @doc """
  Removes defined modules as `principal`, as one set: unloaded from
  the VM, source and beam deleted, committed. Refused with a teaching
  error when a module outside the set depends on one of them, by
  compile-time edge or recorded call, or when one is not a defined
  module. A quarantined module is removable; its whole file goes.
  """
  @spec remove([module()], Principal.t()) :: :ok | {:error, String.t()}
  def remove(modules, %Principal{} = principal) do
    GenServer.call(__MODULE__, {:remove, modules, principal}, 30_000)
  end

  @doc """
  Compiles derived source, the router `Beamlet.Routes` generates, in
  this process's lane, so it never interleaves with a define or a
  boot compile: the compiler options and tracers it swaps are
  VM-global. The modules load into the VM; nothing is written to
  disk, no policy gate runs, no edges are recorded and the server's
  state is untouched. A compile failure returns the error and the
  previously loaded version keeps serving.
  """
  @spec compile_artifact(String.t(), String.t()) :: {:ok, [module()]} | {:error, String.t()}
  def compile_artifact(source, file) when is_binary(source) and is_binary(file) do
    GenServer.call(
      __MODULE__,
      {:compile_artifact, source, file},
      Config.define()[:timeout] + 5_000
    )
  end

  @typedoc "Where a defined module lives: its source, its beam under `ebin/`, and its version when it is a migration."
  @type paths :: %{source_file: Path.t(), beam_file: Path.t(), migration: pos_integer() | nil}

  @doc "The defined modules, sorted. Read from the server's table, so it never waits on a define."
  @spec defined() :: [module()]
  def defined do
    __MODULE__ |> :ets.match({:defined, :"$1", :_, :_, :_}) |> List.flatten() |> Enum.sort()
  end

  @doc "The defined modules with their paths. A table read, like `defined/0`."
  @spec manifest() :: %{module() => paths()}
  def manifest do
    __MODULE__
    |> :ets.match_object({:defined, :_, :_, :_, :_})
    |> Map.new(fn {:defined, mod, source_file, beam_file, migration} ->
      {mod, %{source_file: source_file, beam_file: beam_file, migration: migration}}
    end)
  end

  @doc "The compile-time edges between defined modules: each module to those it depends on."
  @spec deps() :: %{module() => [module()]}
  def deps, do: GenServer.call(__MODULE__, :deps)

  @doc "The runtime call records: caller to callee to the functions called."
  @spec calls() :: %{module() => %{module() => [{atom(), arity()}]}}
  def calls, do: GenServer.call(__MODULE__, :calls)

  @doc "The files quarantined at boot, by file. A table read, like `defined/0`."
  @spec quarantined() :: [quarantine_entry()]
  def quarantined do
    __MODULE__
    |> :ets.match_object({:quarantined, :_, :_, :_})
    |> Enum.map(fn {:quarantined, file, modules, error} ->
      %{file: file, modules: modules, error: error}
    end)
    |> Enum.sort_by(& &1.file)
  end

  @impl GenServer
  def init(opts) do
    Audit.check!()
    code_dir = Keyword.get_lazy(opts, :code_dir, &Config.code_dir/0)
    lib_dir = Path.join(code_dir, "lib")
    migrations_dir = Path.join(code_dir, "migrations")
    ebin_dir = Path.join(code_dir, "ebin")
    staging_dir = Path.join(code_dir, ".staging")

    File.mkdir_p!(lib_dir)
    File.mkdir_p!(migrations_dir)
    File.mkdir_p!(ebin_dir)
    File.rm_rf!(staging_dir)
    :ets.new(__MODULE__, [:named_table, :bag, :public])

    state = %{
      code_dir: code_dir,
      lib_dir: lib_dir,
      migrations_dir: migrations_dir,
      ebin_dir: ebin_dir,
      staging_dir: staging_dir,
      modules: %{},
      deps: %{},
      calls: %{},
      quarantined: []
    }

    state = boot_load(state)
    publish(state)
    Audit.after_boot(code_dir)
    {:ok, state}
  end

  # The caller is Anubis's tool process, which a client cancel kills.
  # Monitoring it for the life of the define is what turns a cancel
  # into an abort: a queued define never starts, a compiling one is
  # stopped and rolled back, and a committing one completes.
  @impl GenServer
  def handle_call({:define, code, modules, replace?, principal, timeout}, {caller, _tag}, state) do
    caller_ref = Process.monitor(caller)

    outcome =
      receive do
        {:DOWN, ^caller_ref, :process, _pid, _reason} -> :cancelled
      after
        0 -> run_define(state, code, modules, replace?, principal, timeout, caller_ref)
      end

    Process.demonitor(caller_ref, [:flush])

    case outcome do
      {:ok, summary, state} -> {:reply, {:ok, summary}, state}
      {:error, message} -> {:reply, {:error, message}, state}
      :cancelled -> {:noreply, state}
    end
  end

  def handle_call({:remove, modules, principal}, _from, state) do
    case run_remove(state, modules, principal) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  # An empty root set keeps the tracer out of it: nothing in a derived
  # artifact is an edge between defined modules.
  def handle_call({:compile_artifact, source, file}, _from, state) do
    ctx = %{roots: MapSet.new(), granted: MapSet.new()}

    result =
      with_compiler_env(ctx, fn ->
        try do
          {:ok, source |> Code.compile_string(file) |> Enum.map(&elem(&1, 0))}
        rescue
          exception -> {:error, Exception.message(exception)}
        end
      end)

    {:reply, result, state}
  end

  def handle_call(:deps, _from, state), do: {:reply, state.deps, state}
  def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

  # Define

  defp run_define(_state, _code, [], _replace?, _principal, _timeout, _caller_ref) do
    {:error, "the buffer defines no modules — write one or more top-level defmodules"}
  end

  defp run_define(state, code, buffer_modules, replace?, principal, timeout, caller_ref) do
    with {:ok, new_mods, replaced} <- classify(state, buffer_modules, replace?),
         :ok <- check_not_applied(state, replaced, "replace") do
      dependents =
        state.deps
        |> dependents_closure(replaced)
        |> MapSet.difference(MapSet.new(buffer_modules))
        |> Enum.sort()

      closure_files = Enum.map(dependents, &Map.fetch!(state.modules, &1))
      staging = write_staging(state, code)

      # Fully removed, not just purged: the compiler resolves struct
      # and macro references against loaded modules, so a dependent
      # would silently recompile against the old version if it were
      # still loaded. Absent modules make the parallel compiler wait
      # for the in-flight new versions instead. Rollback restores
      # them from their beams.
      Enum.each(replaced ++ dependents, &remove_module/1)
      clear_records()

      ctx = %{
        roots: MapSet.new([staging | closure_files]),
        granted: MapSet.union(known_module_names(state), MapSet.new(buffer_modules))
      }

      outcome =
        with_compiler_env(ctx, fn ->
          task =
            Task.Supervisor.async_nolink(Beamlet.TaskSupervisor, fn ->
              Kernel.ParallelCompiler.compile([staging | closure_files],
                return_diagnostics: true,
                dest: state.ebin_dir,
                each_module: &capture/3
              )
            end)

          await(task, caller_ref, timeout)
        end)

      previous = replaced ++ dependents

      case outcome do
        {:ok, {:ok, _modules, _warnings}} ->
          with [] <- broken_callers(merge_calls(state, buffer_modules ++ dependents), replaced),
               {:ok, placements} <- placements(state, buffer_modules) do
            commit(
              state,
              code,
              staging,
              buffer_modules,
              replaced,
              dependents,
              principal,
              placements
            )
          else
            {:error, message} ->
              rollback(state, staging, new_mods, previous)
              {:error, message}

            breaks ->
              rollback(state, staging, new_mods, previous)
              {:error, render_broken_callers(breaks)}
          end

        {:ok, {:error, diagnostics, _warnings}} ->
          rollback(state, staging, new_mods, previous)
          {:error, render_compile_error(state, diagnostics, replaced, dependents)}

        :timeout ->
          rollback(state, staging, new_mods, previous)
          {:error, "define timed out after #{timeout}ms — nothing was changed"}

        :cancelled ->
          rollback(state, staging, new_mods, previous)
          :cancelled

        {:exit, reason} ->
          rollback(state, staging, new_mods, previous)
          {:error, "define failed (#{inspect(reason)}) — nothing was changed"}
      end
    end
  end

  # The task's ref is opaque, so once the reply is in hand the monitor
  # is dropped through the Task API rather than Process.demonitor:
  # ignore/1 demonitors with flush and returns nil, since the reply has
  # already been consumed here.
  defp await(%Task{ref: task_ref} = task, caller_ref, timeout) do
    receive do
      {^task_ref, result} ->
        Task.ignore(task)
        {:ok, result}

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        {:exit, reason}

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        stop(task)
        :cancelled
    after
      timeout ->
        stop(task)
        :timeout
    end
  end

  # The parallel compiler monitors its workers rather than linking
  # them, so killing the task alone would leave a module body running
  # on: the workers it is watching go with it.
  defp stop(%Task{pid: pid} = task) do
    workers =
      case Process.info(pid, :monitors) do
        {:monitors, monitors} -> for {:process, worker} <- monitors, do: worker
        nil -> []
      end

    Task.shutdown(task, :brutal_kill)
    Enum.each(workers, &Process.exit(&1, :kill))
  end

  # Collision tiers

  defp classify(state, modules, replace?) do
    known = known_module_names(state)

    {new_mods, replaced, errors} =
      Enum.reduce(modules, {[], [], []}, fn mod, {new_mods, replaced, errors} ->
        cond do
          MapSet.member?(known, mod) ->
            if replace?,
              do: {new_mods, [mod | replaced], errors},
              else: {new_mods, replaced, [exists_error(state, mod) | errors]}

          Code.ensure_loaded?(mod) ->
            {new_mods, replaced, [taken_error(mod) | errors]}

          reserved?(mod) ->
            {new_mods, replaced, [reserved_error(mod) | errors]}

          true ->
            {[mod | new_mods], replaced, errors}
        end
      end)

    # replace: true is permission, not an assertion: a stray flag on
    # a module that turns out to be new risks nothing, and models
    # that have lost track of what exists whipsaw against strictness.
    case Enum.reverse(errors) do
      [] -> {:ok, Enum.reverse(new_mods), Enum.reverse(replaced)}
      errors -> {:error, Enum.join(errors, "\n")}
    end
  end

  # The pending rule: a migration is editable until it has run, the
  # way a developer treats a migration file. Once applied, the only
  # way through is a rollback; refusing here keeps the applied stack
  # and the files in agreement.
  defp check_not_applied(state, modules, verb) do
    versioned = for mod <- modules, version = migration_version(state, mod), do: {mod, version}

    with {:ok, applied} <- read_applied(versioned) do
      case for {mod, version} <- versioned, version in applied, do: {mod, version} do
        [] ->
          :ok

        refused ->
          {:error,
           Enum.map_join(refused, "\n", fn {mod, version} ->
             "cannot #{verb} #{inspect(mod)} — migration #{version} is applied. Roll it " <>
               "back first with Host.Migrator.rollback(), then #{verb} it."
           end)}
      end
    end
  end

  # The tracking table is read only when a migration is in play, so
  # ordinary defines and removes never touch the agent database.
  defp read_applied([]), do: {:ok, []}

  defp read_applied(_migrations) do
    {:ok, Beamlet.Migrations.applied_versions()}
  rescue
    exception ->
      {:error,
       "could not read the migration history (#{Exception.message(exception)}) — " <>
         "nothing was changed"}
  end

  defp exists_error(state, mod) do
    quote_part =
      case moduledoc_first_line(state, mod) do
        nil -> ""
        line -> " — \"#{line}\""
      end

    "#{inspect(mod)} already exists#{quote_part}. To evolve it, call define again " <>
      "with replace: true; to build something new, choose a different name."
  end

  defp taken_error(mod) do
    "#{inspect(mod)} is an existing module on your beamlet and cannot be redefined. " <>
      "Choose another name."
  end

  defp reserved_error(mod) do
    "#{inspect(mod)} — Beamlet.* and Host.* are reserved for your beamlet and its " <>
      "standard library. Choose a name outside them."
  end

  defp reserved?(mod) do
    case Atom.to_string(mod) do
      "Elixir.Beamlet" -> true
      "Elixir.Beamlet." <> _rest -> true
      "Elixir.Host" -> true
      "Elixir.Host." <> _rest -> true
      _other -> false
    end
  end

  defp moduledoc_first_line(state, mod) do
    path = beam_path(state, mod)

    with true <- File.exists?(path),
         {:docs_v1, _, _, _, %{"en" => doc}, _, _} <- Code.fetch_docs(path) do
      doc |> String.split("\n", parts: 2) |> hd() |> String.trim()
    else
      _no_doc -> nil
    end
  end

  # Placement

  # Where each buffer module's source lands. A migration is recognised
  # the way Ecto recognises one, the compiled module exports
  # __migration__/0, and filed under the migrations root with a
  # host-assigned version: a replaced migration keeps the version its
  # file already carries; a new one takes one past the highest version
  # known to either the files on disk or the tracking table, in buffer
  # order. Both sources count because a git rewind can remove an
  # applied migration's file; reborn at that number, a new migration
  # would already be "applied" and migrate would skip it silently.
  defp placements(state, buffer_modules) do
    migrations = Enum.filter(buffer_modules, &function_exported?(&1, :__migration__, 0))

    with {:ok, applied} <- read_applied(migrations) do
      floor = Enum.max(disk_versions(state) ++ applied, fn -> 0 end)

      {placements, _next} =
        Enum.map_reduce(buffer_modules, floor + 1, fn mod, next ->
          cond do
            mod not in migrations ->
              {{mod, {module_path(state.lib_dir, mod), nil}}, next}

            version = migration_version(state, mod) ->
              {{mod, {migration_path(state, version, mod), version}}, next}

            true ->
              {{mod, {migration_path(state, next, mod), next}}, next + 1}
          end
        end)

      {:ok, Map.new(placements)}
    end
  end

  defp disk_versions(state) do
    state.migrations_dir
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(&List.wrap(file_version(&1)))
  end

  defp migration_version(state, mod) do
    case Map.get(state.modules, mod) do
      nil -> nil
      path -> if Path.dirname(path) == state.migrations_dir, do: file_version(path), else: nil
    end
  end

  defp file_version(path) do
    case Integer.parse(Path.basename(path, ".ex")) do
      {version, "_" <> _name} when version > 0 -> version
      _other -> nil
    end
  end

  # Four-digit padding is cosmetic; the version is parsed numerically.
  defp migration_path(state, version, mod) do
    name = mod |> Macro.underscore() |> String.replace("/", "_")
    number = version |> Integer.to_string() |> String.pad_leading(4, "0")
    Path.join(state.migrations_dir, "#{number}_#{name}.ex")
  end

  # Commit and rollback

  defp commit(state, code, staging, buffer_modules, replaced, dependents, principal, placements) do
    compiled = compiled_records()

    Enum.each(split_sources(code), fn {mod, source} ->
      {path, _version} = Map.fetch!(placements, mod)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
      remove_divergent_source(state, mod, path)
    end)

    Enum.each(compiled, fn {:compiled, mod, _file, binary} ->
      File.write!(beam_path(state, mod), binary)
    end)

    File.rm(staging)

    compiled_mods = Enum.map(compiled, fn {:compiled, mod, _file, _binary} -> mod end)

    modules =
      Enum.reduce(buffer_modules, state.modules, fn mod, modules ->
        {path, _version} = Map.fetch!(placements, mod)
        Map.put(modules, mod, path)
      end)

    quarantined =
      Enum.reject(state.quarantined, fn entry ->
        Enum.any?(entry.modules, &(&1 in buffer_modules))
      end)

    calls = merge_calls(state, compiled_mods)

    state = %{
      state
      | modules: modules,
        deps: merge_deps(state, compiled_mods),
        calls: calls,
        quarantined: quarantined
    }

    publish(state)
    Audit.record_define(state.code_dir, buffer_modules, replaced, principal)

    caller_lines = runtime_caller_lines(calls, replaced, buffer_modules)
    {:ok, summary(buffer_modules, replaced, dependents, caller_lines, placements), state}
  end

  # Define does not apply a migration, and the moment of definition is
  # when the cue to run it matters.
  defp summary(buffer_modules, replaced, dependents, caller_lines, placements) do
    lines =
      Enum.map(buffer_modules, fn mod ->
        flag = if mod in replaced, do: "replaced", else: "new"

        case Map.fetch!(placements, mod) do
          {_path, nil} ->
            "Defined #{inspect(mod)} (#{flag})"

          {_path, version} ->
            "Defined #{inspect(mod)} (#{flag}) — migration #{version}, pending: run " <>
              "Host.Migrator.migrate()"
        end
      end)

    lines =
      case dependents do
        [] ->
          lines

        _some ->
          lines ++ ["Recompiled dependents: #{Enum.map_join(dependents, ", ", &inspect/1)}"]
      end

    Enum.join(lines ++ caller_lines, "\n")
  end

  # Callers outside the buffer survive a replace unrecompiled, since
  # their calls resolve at runtime, so the summary names them and
  # what they call, as fact: whether the replacement still suits them
  # is the agent's judgment.
  defp runtime_caller_lines(calls, replaced, buffer_modules) do
    callers =
      for {caller, targets} <- calls,
          caller not in buffer_modules,
          {callee, fas} <- targets,
          callee in replaced,
          fa <- fas,
          do: {caller, fa}

    case callers do
      [] ->
        []

      _some ->
        rendered =
          callers
          |> Enum.group_by(fn {caller, _fa} -> caller end, fn {_caller, fa} -> fa end)
          |> Enum.sort_by(fn {caller, _fas} -> inspect(caller) end)
          |> Enum.map_join(", ", fn {caller, fas} ->
            fas = fas |> Enum.uniq() |> Enum.sort() |> Enum.map_join(", ", &render_fa/1)
            "#{inspect(caller)} (#{fas})"
          end)

        ["Note: called at runtime by #{rendered}"]
    end
  end

  defp broken_callers(calls, replaced) do
    for {caller, targets} <- calls,
        {callee, fas} <- targets,
        callee in replaced,
        {f, a} <- fas,
        not function_exported?(callee, f, a),
        do: {caller, callee, f, a}
  end

  defp render_broken_callers(breaks) do
    breaks
    |> Enum.group_by(fn {caller, callee, _f, _a} -> {caller, callee} end, fn {_c, _r, f, a} ->
      {f, a}
    end)
    |> Enum.sort_by(fn {{caller, callee}, _fas} -> {inspect(callee), inspect(caller)} end)
    |> Enum.map_join("\n", fn {{caller, callee}, fas} ->
      calls =
        fas
        |> Enum.sort()
        |> Enum.map_join(", ", fn {f, a} -> "#{inspect(callee)}.#{f}/#{a}" end)

      "replacing #{inspect(callee)} broke its caller #{inspect(caller)} — " <>
        "#{inspect(caller)} calls #{calls}, which the replacement no longer defines. " <>
        "Nothing was changed. Update #{inspect(caller)} in the same buffer, or keep #{calls}."
    end)
  end

  defp render_fa({f, a}), do: "#{f}/#{a}"

  # A replaced module whose previous source lives at another path, a
  # quarantined hand edit or an odd hand-made layout, must lose that
  # file, or boot would compile the module twice.
  defp remove_divergent_source(state, mod, path) do
    case Map.get(state.modules, mod) do
      nil -> :ok
      ^path -> :ok
      old_path -> File.rm(old_path)
    end

    state.quarantined
    |> Enum.filter(fn entry -> mod in entry.modules and entry.file != path end)
    |> Enum.each(fn entry -> File.rm(entry.file) end)
  end

  defp rollback(state, staging, new_mods, previous_mods) do
    Enum.each(new_mods, &remove_module/1)

    Enum.each(previous_mods, fn mod ->
      path = beam_path(state, mod)

      case File.read(path) do
        {:ok, binary} ->
          :code.purge(mod)
          :code.load_binary(mod, String.to_charlist(path), binary)
          :code.purge(mod)

        {:error, _reason} ->
          remove_module(mod)
      end
    end)

    File.rm(staging)
    :ok
  end

  defp remove_module(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
  end

  defp render_compile_error(state, diagnostics, replaced, dependents) do
    dependent_files = Map.new(dependents, fn mod -> {Map.fetch!(state.modules, mod), mod} end)

    case Enum.find(diagnostics, &Map.has_key?(dependent_files, &1.file)) do
      nil ->
        Enum.map_join(diagnostics, "\n", fn diagnostic ->
          "line #{diag_line(diagnostic)}: #{diagnostic.message}"
        end)

      diagnostic ->
        dependent = Map.fetch!(dependent_files, diagnostic.file)
        replaced_names = Enum.map_join(replaced, ", ", &inspect/1)

        "replacing #{replaced_names} broke its dependent #{inspect(dependent)} — " <>
          "line #{diag_line(diagnostic)}: #{diagnostic.message} Nothing was changed. " <>
          "Update #{inspect(dependent)} in the same buffer, or keep #{replaced_names} compatible."
    end
  end

  defp diag_line(%{position: {line, _column}}), do: line
  defp diag_line(%{position: line}) when is_integer(line), do: line
  defp diag_line(_diagnostic), do: 0

  # Remove

  defp run_remove(_state, [], _principal) do
    {:error, "remove names no modules — pass a module or a list of modules"}
  end

  defp run_remove(state, modules, principal) do
    modules = Enum.uniq(modules)

    with :ok <- check_removable(state, modules),
         :ok <- check_not_applied(state, modules, "remove"),
         :ok <- check_not_routed(modules),
         :ok <- check_dependents(state, modules) do
      execute_remove(state, modules, principal)
    end
  end

  # A mounted route names its module by inspect form and would answer
  # 404 the moment the module went; refusing here keeps the removal
  # and the check atomic, as the dependents check is.
  defp check_not_routed(modules) do
    case Beamlet.Routes.list(modules: Enum.map(modules, &inspect/1)) do
      [] ->
        :ok

      routes ->
        {:error,
         Enum.map_join(routes, "\n", fn route ->
           verb = route.verb |> Atom.to_string() |> String.upcase()

           "cannot remove #{route.module} — #{verb} #{route.path} is mounted on it. " <>
             "Unmount it first: Host.Router.unmount(#{inspect(route.path)})."
         end)}
    end
  rescue
    exception ->
      {:error,
       "could not read the route table (#{Exception.message(exception)}) — " <>
         "nothing was changed"}
  end

  defp check_removable(state, modules) do
    errors =
      modules
      |> Enum.reject(fn mod ->
        Map.has_key?(state.modules, mod) or quarantine_member?(state, mod)
      end)
      |> Enum.map(fn mod ->
        if Code.ensure_loaded?(mod) do
          "Host.Code.remove removes defined modules only — #{inspect(mod)} is part of " <>
            "your beamlet."
        else
          "#{inspect(mod)} is not a defined module — Host.Code.print_modules() shows what is."
        end
      end)

    if errors == [], do: :ok, else: {:error, Enum.join(errors, "\n")}
  end

  defp check_dependents(state, modules) do
    removal = MapSet.new(modules)
    lines = Enum.flat_map(modules, &dependent_lines(state, &1, removal))

    case lines do
      [] ->
        :ok

      _some ->
        {:error,
         Enum.join(lines, "\n") <>
           "\nRemove or rework the dependents first, or remove them together in one " <>
           "remove call."}
    end
  end

  defp dependent_lines(state, target, removal) do
    descriptions =
      state.modules
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(removal, &1))
      |> Enum.sort_by(&inspect/1)
      |> Enum.flat_map(fn mod ->
        compile? = target in Map.get(state.deps, mod, [])
        fas = state.calls |> Map.get(mod, %{}) |> Map.get(target)

        uses =
          case {fas, compile?} do
            {nil, false} ->
              nil

            {nil, true} ->
              "depends on it at compile time"

            {fas, false} ->
              "calls #{Enum.map_join(fas, ", ", &render_fa/1)}"

            {fas, true} ->
              "calls #{Enum.map_join(fas, ", ", &render_fa/1)} and depends on it at compile time"
          end

        if uses, do: ["#{inspect(mod)} #{uses}"], else: []
      end)

    case descriptions do
      [] -> []
      _some -> ["cannot remove #{inspect(target)} — #{Enum.join(descriptions, "; ")}."]
    end
  end

  defp execute_remove(state, modules, principal) do
    {defined, from_quarantine} = Enum.split_with(modules, &Map.has_key?(state.modules, &1))

    Enum.each(defined, fn mod ->
      remove_module(mod)
      File.rm(Map.fetch!(state.modules, mod))
      File.rm(beam_path(state, mod))
    end)

    # A quarantined file is the unit of deletion: removing one of its
    # modules takes the file, and with it any siblings a hand edit
    # packed in.
    {removed_entries, quarantined} =
      Enum.split_with(state.quarantined, fn entry ->
        Enum.any?(entry.modules, &(&1 in from_quarantine))
      end)

    Enum.each(removed_entries, fn entry -> File.rm(entry.file) end)
    Enum.each(from_quarantine, fn mod -> File.rm(beam_path(state, mod)) end)

    state = %{
      state
      | modules: Map.drop(state.modules, defined),
        deps: Map.drop(state.deps, defined),
        calls: Map.drop(state.calls, defined),
        quarantined: quarantined
    }

    publish(state)
    Audit.record_remove(state.code_dir, modules, principal)
    {:ok, state}
  end

  defp quarantine_member?(state, mod) do
    Enum.any?(state.quarantined, fn entry -> mod in entry.modules end)
  end

  # Boot loading

  # Both roots compile in one batch: a migration and the schema module
  # it precedes are ordinary cross-file references to the compiler.
  defp boot_load(state) do
    files =
      Enum.sort(
        Path.wildcard(Path.join(state.lib_dir, "**/*.ex")) ++
          Path.wildcard(Path.join(state.migrations_dir, "*.ex"))
      )

    boot_loop(state, files, [])
  end

  defp boot_loop(state, [], quarantined) do
    %{state | modules: %{}, deps: %{}, calls: %{}, quarantined: Enum.reverse(quarantined)}
  end

  defp boot_loop(state, files, quarantined) do
    clear_records()
    file_modules = Map.new(files, &{&1, parse_modules(&1)})

    # Quarantined names stay in the granted set so edges to them
    # survive a later recovery.
    granted =
      (file_modules |> Map.values() |> List.flatten()) ++
        Enum.flat_map(quarantined, & &1.modules)

    ctx = %{roots: MapSet.new(files), granted: MapSet.new(granted)}

    result =
      with_compiler_env(ctx, fn ->
        Kernel.ParallelCompiler.compile(files,
          return_diagnostics: true,
          dest: state.ebin_dir,
          each_module: &capture/3
        )
      end)

    case result do
      {:ok, _modules, _warnings} ->
        finalize_boot(state, quarantined)

      {:error, diagnostics, _warnings} ->
        bad_files =
          diagnostics
          |> Enum.map(& &1.file)
          |> Enum.uniq()
          |> Enum.filter(&(&1 in files))

        # An unattributable failure quarantines everything remaining
        # rather than looping forever.
        bad_files = if bad_files == [], do: files, else: bad_files

        entries =
          Enum.map(bad_files, fn file ->
            error = boot_error(diagnostics, file)
            Logger.warning("code boot: quarantined #{relative(state, file)}: #{error}")
            %{file: file, modules: Map.fetch!(file_modules, file), error: error}
          end)

        purge_captured(bad_files)
        boot_loop(state, files -- bad_files, Enum.reverse(entries) ++ quarantined)
    end
  end

  defp finalize_boot(state, quarantined) do
    compiled = compiled_records()

    Enum.each(compiled, fn {:compiled, mod, _file, binary} ->
      File.write!(beam_path(state, mod), binary)
    end)

    prune_ebin(state, Enum.map(compiled, fn {:compiled, mod, _file, _binary} -> mod end))

    modules = Map.new(compiled, fn {:compiled, mod, file, _binary} -> {mod, file} end)
    state = %{state | modules: modules}

    %{
      state
      | deps: merge_deps(%{state | deps: %{}}, Map.keys(modules)),
        calls: merge_calls(%{state | calls: %{}}, Map.keys(modules)),
        quarantined: Enum.reverse(quarantined)
    }
  end

  defp boot_error(diagnostics, file) do
    case Enum.find(diagnostics, &(&1.file == file)) do
      nil -> "failed alongside another file"
      diagnostic -> diagnostic.message |> String.split("\n", parts: 2) |> hd()
    end
  end

  # Between quarantine rounds every recompiled module gains an old-code
  # slot the next load would trip over; modules from a failing file may
  # also have loaded before the failure and must go entirely.
  defp purge_captured(bad_files) do
    Enum.each(compiled_records(), fn {:compiled, mod, file, _binary} ->
      if file in bad_files, do: remove_module(mod), else: :code.purge(mod)
    end)
  end

  defp prune_ebin(state, keep) do
    keep = MapSet.new(keep, &Path.basename(beam_path(state, &1)))

    state.ebin_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(keep, Path.basename(&1)))
    |> Enum.each(&File.rm/1)
  end

  # The table

  defp capture(file, mod, binary), do: :ets.insert(__MODULE__, {:compiled, mod, file, binary})

  defp compiled_records, do: :ets.match_object(__MODULE__, {:compiled, :_, :_, :_})

  defp clear_records do
    :ets.delete(__MODULE__, :compiled)
    :ets.delete(__MODULE__, :edge)
    :ets.delete(__MODULE__, :call)
  end

  # Rows are added before stale ones go, so a scan in flight never
  # sees a defined module missing.
  defp publish(state) do
    current =
      MapSet.new(
        Enum.map(state.modules, fn {mod, source_file} ->
          {:defined, mod, source_file, beam_path(state, mod), migration_version(state, mod)}
        end) ++
          Enum.map(state.quarantined, fn entry ->
            {:quarantined, entry.file, entry.modules, entry.error}
          end)
      )

    published =
      MapSet.new(
        :ets.match_object(__MODULE__, {:defined, :_, :_, :_, :_}) ++
          :ets.match_object(__MODULE__, {:quarantined, :_, :_, :_})
      )

    for row <- MapSet.difference(current, published), do: :ets.insert(__MODULE__, row)
    for row <- MapSet.difference(published, current), do: :ets.delete_object(__MODULE__, row)
    :ok
  end

  # Runtime compilation ships no docs chunk by default, but docs are
  # the discovery surface and must ride the beams; module-conflict
  # warnings are noise for a deliberate replace. Both are VM-global
  # compiler options, like the tracer: set only around the server's
  # serialized compiles, restored after.
  defp with_compiler_env(ctx, fun) do
    previous_tracers = Tracer.install(ctx)
    previous_docs = Code.get_compiler_option(:docs)
    previous_conflict = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:docs, true)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      fun.()
    after
      Code.put_compiler_option(:docs, previous_docs)
      Code.put_compiler_option(:ignore_module_conflict, previous_conflict)
      Tracer.uninstall(previous_tracers)
    end
  end

  defp merge_deps(state, compiled_mods) do
    by_source =
      __MODULE__
      |> :ets.match_object({:edge, :_, :_})
      |> Enum.group_by(fn {:edge, source, _target} -> source end, fn {:edge, _source, target} ->
        target
      end)

    new_deps = Map.new(compiled_mods, fn mod -> {mod, Enum.uniq(Map.get(by_source, mod, []))} end)
    Map.merge(state.deps, new_deps)
  end

  defp merge_calls(state, compiled_mods) do
    by_source =
      __MODULE__
      |> :ets.match_object({:call, :_, :_, :_, :_})
      |> Enum.group_by(fn {:call, source, _target, _f, _a} -> source end)

    new_calls =
      Map.new(compiled_mods, fn mod ->
        targets =
          by_source
          |> Map.get(mod, [])
          |> Enum.group_by(
            fn {:call, _source, target, _f, _a} -> target end,
            fn {:call, _source, _target, f, a} -> {f, a} end
          )
          |> Map.new(fn {target, fas} -> {target, Enum.sort(fas)} end)

        {mod, targets}
      end)

    Map.merge(state.calls, new_calls)
  end

  defp dependents_closure(deps, targets) do
    expand_closure(deps, MapSet.new(targets))
  end

  defp expand_closure(deps, set) do
    additions =
      for {mod, targets} <- deps,
          not MapSet.member?(set, mod),
          Enum.any?(targets, &MapSet.member?(set, &1)),
          do: mod

    case additions do
      [] -> set
      _some -> expand_closure(deps, MapSet.union(set, MapSet.new(additions)))
    end
  end

  defp known_module_names(state) do
    quarantined = Enum.flat_map(state.quarantined, & &1.modules)
    MapSet.new(Map.keys(state.modules) ++ quarantined)
  end

  # Sources

  defp parse_modules(file) do
    with {:ok, code} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(code) do
      ast
      |> block_forms()
      |> Enum.flat_map(fn
        {:defmodule, _meta, [{:__aliases__, _, parts} | _rest]} ->
          if is_list(parts) and Enum.all?(parts, &is_atom/1),
            do: [Module.concat(parts)],
            else: []

        _other ->
          []
      end)
    else
      _unreadable -> []
    end
  end

  defp write_staging(state, code) do
    File.mkdir_p!(state.staging_dir)
    path = Path.join(state.staging_dir, "define_#{System.unique_integer([:positive])}.ex")
    File.write!(path, code)
    path
  end

  # One file per module: each module's slice runs from the end of the
  # previous one, so a comment above a module travels with it.
  defp split_sources(code) do
    {:ok, ast} = Code.string_to_quoted(code, token_metadata: true)
    lines = String.split(code, "\n")

    ranges =
      ast
      |> block_forms()
      |> Enum.flat_map(fn
        {:defmodule, meta, [{:__aliases__, _, parts} | _rest]} ->
          [{Module.concat(parts), meta[:line], meta[:end][:line]}]

        _other ->
          []
      end)

    ranges
    |> fill_end_lines(length(lines))
    |> Enum.map_reduce(0, fn {mod, _start_line, end_line}, prev_end ->
      source =
        lines
        |> Enum.slice(prev_end, end_line - prev_end)
        |> Enum.join("\n")
        |> String.replace(~r/\A\n+/, "")

      {{mod, source <> "\n"}, end_line}
    end)
    |> elem(0)
  end

  # A `defmodule Foo, do: ...` one-liner has no end token; its slice
  # runs to the next module's preceding line.
  defp fill_end_lines(ranges, total_lines) do
    ranges
    |> Enum.with_index()
    |> Enum.map(fn {{mod, start_line, end_line}, index} ->
      end_line =
        end_line ||
          case Enum.at(ranges, index + 1) do
            {_mod, next_start, _end} -> next_start - 1
            nil -> total_lines
          end

      {mod, start_line, end_line}
    end)
  end

  defp block_forms({:__block__, _meta, forms}), do: forms
  defp block_forms(form), do: [form]

  defp module_path(lib_dir, mod), do: Path.join(lib_dir, Macro.underscore(mod) <> ".ex")

  defp beam_path(state, mod), do: Path.join(state.ebin_dir, "#{mod}.beam")

  defp relative(state, file), do: Path.relative_to(file, state.code_dir)
end
