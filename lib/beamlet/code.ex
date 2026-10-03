defmodule Beamlet.Code do
  @moduledoc """
  The code server: the modules defined on your beamlet, their sources
  and beams under the data dir, and the git history of both.

  Everything an agent defines lives under `<data_dir>/code`:

      code/
        lib/         one source file per module, shopping/list.ex for Shopping.List
        migrations/  one file per migration, 0001_shopping_create_lists.ex
        ebin/        the compiled beams, with docs, rebuilt from the sources at boot
        .git       the history: one commit per define, patch or remove
        .staging   the modules being compiled, each at the path it will
                   be stored at, gone when the define is done

  Source is stored as the formatter lays it out, and a module's path
  follows from its name, so every error and stack trace an agent
  reads locates as `lib/shopping/list.ex:42`, a line of the stored
  source that `Host.Code.print_source/1` prints.

  The `define` and `patch` tools and `Host.Code.remove` are calls
  into this process, so mutations serialize and two writers never
  race the code dir. A patch is a define of the patched modules that
  also carries a hash of the source each patch read, compared here
  inside the lane, so a module that changed in between is refused
  rather than overwritten. A define is all-or-nothing: the modules compile into the
  VM first, and sources and beams are written only after every check
  has passed; a failed compile, a timeout, or a client cancelling the
  request rolls the VM back by reloading the previous beams, and
  nothing on disk has changed. The one accepted window is that
  compilation loads modules as it goes, so an eval running at the
  same moment can observe a half-loaded new version for a few
  milliseconds, and replacing a module an eval is still executing
  old code of will kill that eval.

  The defined modules are the ones each file declares with a
  top-level `defmodule`. A macro can create more as a file compiles,
  an inline embedded schema among them; those are generated, owned
  by a module of their file. They load and keep their beams, but
  cannot be defined or removed on their own, and they go when their
  owner goes or stops producing them.

  A module that uses `Ecto.Migration` is a migration: it is filed
  under `migrations/` with the next version number, one past both
  the files on disk and the versions the agent database records as
  applied, and stays editable until `Host.Migrator` applies it. An
  applied migration must be rolled back before it can be replaced or
  removed, so the applied stack and the files never disagree.

  Boot compiles the code dir, rebuilding the dependency map and the
  beams. A module that fails to compile, a bad hand edit or a
  beamlet upgrade, or one whose function clauses are scattered, is
  quarantined: skipped, logged and held in the server's state, never
  taking the beamlet down. Boot compiles carry no policy gate: the
  scanner runs when code is submitted through the tools, and the
  code dir's contents were either scanned on the way in or
  hand-edited by the operator, who is trusted.

  The dependency map has two halves, both between defined modules,
  where a generated module counts as its owner on either end.
  Compile-time edges, from structs, macros, imports and requires,
  drive replace's dependent recompiles. Runtime call records, caller
  to callee function and arity, drive remove's refusal and replace's
  check that a dropped function is not still called. A plain remote
  call resolves by name when it runs and is never stale, so it never
  triggers a recompile. The map blocks only provable breakage:
  removing a module something references, or replacing away a
  function something still calls.

  Git holds the history. Beamlet commits after every define, patch
  and remove, with the token as the author (`laptop <laptop@beamlet>`) and
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
  alias Beamlet.Code.Docs
  alias Beamlet.Code.Entry
  alias Beamlet.Code.Source
  alias Beamlet.Code.Tracer
  alias Beamlet.Config
  alias Beamlet.Principal
  alias Beamlet.Scanner

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

  @typedoc """
  One module to define, as the runtime hands it over: its name, its
  formatted source, whether it is a migration (from its
  `use Ecto.Migration` line), and whether it may replace a module of
  the same name. A patched module also carries `hash`, the SHA-256
  of the stored source the patch read, and `label`, the patch or
  patches that produced it, which prefixes every error located in
  it.
  """
  @type entry :: %{
          required(:module) => module(),
          required(:source) => String.t(),
          required(:kind) => :module | :migration,
          required(:replace) => boolean(),
          optional(:hash) => binary(),
          optional(:label) => String.t()
        }

  @doc """
  Defines `entries` as `principal`: checks the names, compiles them
  with the dependents of any replaced module, then persists and
  loads, all-or-nothing. Each entry's source is scanned, checked and
  formatted already (`Beamlet.Define`), and is stored byte for byte.

  Returns the summary the agent reads, or a teaching error. The
  compile timeout comes from `config :beamlet, :define`;
  `opts[:timeout]` overrides it. The call itself waits as long as it
  takes: a define may wait behind any number of others, and the
  caller's own lifetime bounds the wait, since a caller that dies
  while queued is never served.

  `opts[:verb]` is `:define` or `:patch` (`Beamlet.Patch`): a patch
  compares each entry's `hash` with the file on disk before anything
  else, summarises as `Patched` and commits as `patch:`.
  `opts[:context]` is how many lines an error quotes either side of
  the failing one, as `Beamlet.Scanner.locate/5` takes it; a patch
  passes some, since the failing text exists nowhere the agent can
  read.
  """
  @spec define([entry()], Principal.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def define(entries, %Principal{} = principal, opts \\ []) when is_list(entries) do
    timeout = Keyword.get_lazy(opts, :timeout, fn -> Config.define()[:timeout] end)

    run = %{
      timeout: timeout,
      verb: Keyword.get(opts, :verb, :define),
      context: Keyword.get(opts, :context, 0)
    }

    GenServer.call(__MODULE__, {:define, entries, principal, run}, :infinity)
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
    GenServer.call(__MODULE__, {:remove, modules, principal}, :infinity)
  end

  @doc """
  Compiles derived quoted form, the router `Beamlet.Routes`
  generates, in this process's lane, so it never interleaves with a
  define, a boot compile or another artifact compile: the compiler
  options and tracers it swaps are VM-global.

  `source` returns the quoted form and runs inside the lane too, so
  whatever it reads is current when the compile runs, and two
  callers can never land their builds out of order. It runs in this
  process, so it must not call this server. The modules load into
  the VM; nothing is written to disk, no policy gate runs and no
  edges are recorded. A raise in `source` or a compile failure
  returns the error and puts back the last version this server
  compiled from the same file, so it keeps serving.
  """
  @spec compile_artifact((-> Macro.t()), String.t()) :: {:ok, [module()]} | {:error, String.t()}
  def compile_artifact(source, file) when is_function(source, 0) and is_binary(file) do
    GenServer.call(__MODULE__, {:compile_artifact, source, file}, :infinity)
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

  @doc """
  The file holding a module's source. A table read, like `defined/0`.

  A quarantined module counts: it has a source and no beam, and its
  file is the one `print_source` shows and patch edits.
  """
  @spec source_file(module()) :: {:ok, Path.t()} | :error
  def source_file(mod) do
    case :ets.match(__MODULE__, {:defined, mod, :"$1", :_, :_}) do
      [[source_file] | _] ->
        {:ok, source_file}

      [] ->
        case Enum.find(quarantined(), &(mod in &1.modules)) do
          %{file: file} -> {:ok, file}
          nil -> :error
        end
    end
  end

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

    # The table, a bag keyed by row kind. Per compile, written while
    # it runs; :ctx lives from Tracer.install/1 to Tracer.uninstall/1,
    # and clear_records/0 clears the rest before the next compile:
    #
    #   {:ctx, ctx}                          the roots and defined names
    #                                        the tracer reads
    #   {:compiled, mod, file, binary}       each module compiled; capture/3
    #   {:edge, from, to}                    a compile-time dependency; Tracer
    #   {:call, caller, callee, fun, arity}  a remote call; Tracer
    #
    # Published, rewritten from the state by publish/1 after every
    # change, and read outside the lane by defined/0, manifest/0,
    # quarantined/0 and source_file/1:
    #
    #   {:defined, mod, source_file, beam_file, migration}
    #   {:quarantined, file, modules, error}
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
      generated: %{},
      quarantined: [],
      artifacts: %{}
    }

    state = boot_load(state)
    publish(state)
    Audit.after_boot(code_dir)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:define, entries, principal, run}, {caller, _tag}, state) do
    outcome =
      unless_cancelled(caller, fn caller_ref ->
        run_define(state, entries, principal, run, caller_ref)
      end)

    case outcome do
      {:ok, summary, state} -> {:reply, {:ok, summary}, state}
      {:error, message} -> {:reply, {:error, message}, state}
      :cancelled -> {:noreply, state}
    end
  end

  def handle_call({:remove, modules, principal}, {caller, _tag}, state) do
    case unless_cancelled(caller, fn _caller_ref -> run_remove(state, modules, principal) end) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, message} -> {:reply, {:error, message}, state}
      :cancelled -> {:noreply, state}
    end
  end

  def handle_call({:compile_artifact, source, file}, {caller, _tag}, state) do
    case unless_cancelled(caller, fn _caller_ref -> run_compile_artifact(source, file) end) do
      {:ok, compiled} ->
        {:reply, {:ok, Enum.map(compiled, &elem(&1, 0))}, put_in(state.artifacts[file], compiled)}

      {:error, _message} = error ->
        restore_artifact(Map.get(state.artifacts, file, []), file)
        {:reply, error, state}

      :cancelled ->
        {:noreply, state}
    end
  end

  # The caller is Anubis's tool process or an eval's child, which a
  # client cancel or the eval's timeout kills. A call still queued
  # when its caller died never starts, so a cancel is an abort. A
  # define also hands the monitor to its compile, which stops and
  # rolls back on it; a remove or an artifact compile, once started,
  # completes. A monitor on a process already dead signals its DOWN,
  # which a `receive` with `after 0` can run ahead of, so the check
  # is `Process.alive?/1`, taken after the monitor so a death in
  # between still reaches it.
  defp unless_cancelled(caller, fun) do
    caller_ref = Process.monitor(caller)
    outcome = if Process.alive?(caller), do: fun.(caller_ref), else: :cancelled
    Process.demonitor(caller_ref, [:flush])
    outcome
  end

  # Define

  defp run_define(_state, [], _principal, %{verb: :define}, _caller_ref) do
    {:error, "define names no modules — pass one entry per module"}
  end

  defp run_define(_state, [], _principal, %{verb: :patch}, _caller_ref) do
    {:error, "patch names no modules — pass one patch per change"}
  end

  # A run is one define or patch going through the lane: one map the
  # stages grow, each adding its keys.
  #
  #   define/3    timeout, verb, context
  #   prepare/4   entries, principal, entry_modules, new, replaced,
  #               placements ({path, version} per module), dependents
  #   stage/2     staged ({module, staging file}), files (what the
  #               compiler takes: staged and dependents' files),
  #               previous (the versions unloaded), locators
  #
  # Every stage after stage/2 has changed something, so any failure
  # from there rolls back here, and nowhere else.
  defp run_define(state, entries, principal, run, caller_ref) do
    with {:ok, run} <- prepare(state, entries, principal, run) do
      run = stage(state, run)

      result =
        with {:ok, warnings} <- compile(state, run, caller_ref),
             :ok <- verify(state, run, warnings) do
          commit(state, run)
        end

      case result do
        {:ok, _summary, _state} ->
          result

        failure ->
          rollback(state, run)
          failure
      end
    end
  end

  # Every check that needs no compile, and the dependents a replace
  # recompiles. Nothing has changed yet, so a refusal needs no undo.
  defp prepare(state, entries, principal, run) do
    entry_modules = Enum.map(entries, & &1.module)

    with :ok <- check_hashes(state, entries),
         {:ok, new, replaced} <- classify(state, entries),
         :ok <- check_not_applied(state, replaced, verb_word(run.verb)),
         {:ok, placements} <- placements(state, entries),
         :ok <- check_paths(state, entries, placements) do
      dependents =
        state.deps
        |> dependents_closure(replaced)
        |> MapSet.difference(MapSet.new(entry_modules))
        |> Enum.sort()

      {:ok,
       Map.merge(run, %{
         entries: entries,
         principal: principal,
         entry_modules: entry_modules,
         new: new,
         replaced: replaced,
         placements: placements,
         dependents: dependents
       })}
    end
  end

  defp stage(state, run) do
    staged = write_staging(state, run.entries, run.placements)
    dependent_files = Enum.map(run.dependents, &Map.fetch!(state.modules, &1))

    # Fully removed, not just purged: the compiler resolves struct
    # and macro references against loaded modules, so a dependent
    # would silently recompile against the old version if it were
    # still loaded. Absent modules make the parallel compiler wait
    # for the in-flight new versions instead. Rollback restores
    # them from their beams.
    previous = with_generated(state, run.replaced ++ run.dependents)
    Enum.each(previous, &remove_module/1)
    clear_records()

    Map.merge(run, %{
      staged: staged,
      files: Enum.map(staged, fn {_mod, file} -> file end) ++ dependent_files,
      previous: previous,
      locators: locators(state, staged, run)
    })
  end

  defp compile(state, run, caller_ref) do
    ctx = %{roots: MapSet.new(run.files), defined: known_in_run(state, run), ebin: ebin(state)}

    outcome =
      with_compiler_env(ctx, fn ->
        task =
          Task.Supervisor.async_nolink(Beamlet.TaskSupervisor, fn ->
            Kernel.ParallelCompiler.compile(run.files,
              return_diagnostics: true,
              dest: state.ebin_dir,
              each_module: &capture/3
            )
          end)

        await(task, caller_ref, run.timeout)
      end)

    case outcome do
      {:ok, {:ok, _modules, %{compile_warnings: warnings}}} ->
        {:ok, warnings}

      {:ok, {:error, diagnostics, _warnings}} ->
        render = %{
          context: run.context,
          locators: run.locators,
          code_dir: state.code_dir,
          staging_dir: state.staging_dir
        }

        {:error, render_compile_error(state, diagnostics, render, run.replaced, run.dependents)}

      :timeout ->
        {:error, "#{run.verb} timed out after #{run.timeout}ms — nothing was changed"}

      :cancelled ->
        :cancelled

      {:exit, reason} ->
        {:error, "#{run.verb} failed (#{inspect(reason)}) — nothing was changed"}
    end
  end

  # What only the compiled modules can show: clauses the compiler
  # warned are scattered, a kind the `use` line did not predict, and
  # a replaced module's callers left calling what it dropped.
  defp verify(state, run, warnings) do
    with :ok <- check_grouped(warnings, run.locators),
         :ok <- check_kinds(run.entries) do
      owners = compile_owners(state, run.entry_modules)
      known = known_in_run(state, run)
      calls = merge_calls(state, run.entry_modules ++ run.dependents, owners, known)

      case broken_callers(calls, run.replaced, Map.merge(state.generated, owners)) do
        [] -> :ok
        breaks -> {:error, render_broken_callers(breaks)}
      end
    end
  end

  defp verb_word(:define), do: "replace"
  defp verb_word(:patch), do: "patch"

  # The stale-read guard. A patch hashes the source it read; the file
  # on disk is hashed here, where nothing else can write, and a
  # difference means another writer got in between. A module with no
  # file left counts as changed with its own wording, since classify
  # would otherwise file the patch as a new module.
  defp check_hashes(state, entries) do
    refusals =
      for %{module: mod, hash: hash} <- entries, is_binary(hash), reduce: [] do
        refusals ->
          with {:ok, file} <- source_file(state, mod),
               {:ok, bytes} <- File.read(file) do
            if :crypto.hash(:sha256, bytes) == hash,
              do: refusals,
              else: [
                "#{inspect(mod)} changed while you were patching it — read it again and " <>
                  "patch the current source. Nothing was changed."
                | refusals
              ]
          else
            _missing ->
              [
                "#{inspect(mod)} was removed while you were patching it — nothing was changed. " <>
                  "Host.Code.print_modules() shows what is defined."
                | refusals
              ]
          end
      end

    case refusals do
      [] -> :ok
      _some -> {:error, refusals |> Enum.reverse() |> Enum.join("\n")}
    end
  end

  # What every compiled file is called in an error: a staged entry by
  # the path its module will be stored at, a dependent by the path it
  # is stored at, both relative to the code dir. The source beside it
  # is what the quoted line is read from, held here because the
  # staged copy is gone by the time an error renders. A patched
  # entry's label names the patches that produced it.
  defp locators(state, staged, run) do
    labels = Map.new(run.entries, fn entry -> {entry.module, Map.get(entry, :label)} end)

    staged_locators =
      Map.new(staged, fn {mod, staging_file} ->
        {path, _version} = Map.fetch!(run.placements, mod)
        source = File.read!(staging_file)

        {staging_file,
         %{module: mod, locator: relative(state, path), source: source, label: labels[mod]}}
      end)

    Map.new(run.dependents, fn mod ->
      file = Map.fetch!(state.modules, mod)
      {file, %{module: mod, locator: relative(state, file), source: File.read!(file), label: nil}}
    end)
    |> Map.merge(staged_locators)
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

  defp classify(state, entries) do
    known = known_module_names(state)

    {new_mods, replaced, errors} =
      Enum.reduce(entries, {[], [], []}, fn %{module: mod} = entry,
                                            {new_mods, replaced, errors} ->
        cond do
          MapSet.member?(known, mod) ->
            if entry.replace,
              do: {new_mods, [mod | replaced], errors},
              else: {new_mods, replaced, [exists_error(state, mod) | errors]}

          owner = Map.get(state.generated, mod) ->
            {new_mods, replaced,
             [generated_error(state, mod, owner, "choose another name") | errors]}

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
      case moduledoc_summary(state, mod) do
        nil -> ""
        summary -> " — \"#{summary}\""
      end

    "#{inspect(mod)} already exists#{quote_part}. To change it, patch it; to rewrite it " <>
      "whole, set replace: true on its entry; to build something new, choose a different name."
  end

  defp generated_error(state, mod, owner, advice) do
    "#{inspect(mod)} is generated by the source of #{inspect(owner)} " <>
      "(#{relative(state, Map.fetch!(state.modules, owner))}), an embedded schema or the " <>
      "like — #{advice}."
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
      _other -> Scanner.host_module?(mod)
    end
  end

  defp moduledoc_summary(state, mod) do
    path = beam_path(state, mod)

    with true <- File.exists?(path),
         {:docs_v1, _, _, _, %{"en" => doc}, _, _} <- Code.fetch_docs(path) do
      Docs.summary(doc)
    else
      _no_doc -> nil
    end
  end

  # Placement

  @path_rule "a module's file is named for its underscored name, so names that " <>
               "differ only in capitalisation share one."

  # Where each entry's source lands, decided before the compile so the
  # staged file already carries the path every error names. A
  # migration is recognised by its `use Ecto.Migration` line and filed
  # under the migrations root with a host-assigned version: a replaced
  # migration keeps the version its file already carries; a new one
  # takes one past the highest version known to either the files on
  # disk or the tracking table, in entry order. Both sources count
  # because a git rewind can remove an applied migration's file;
  # reborn at that number, a new migration would already be "applied"
  # and migrate would skip it silently.
  defp placements(state, entries) do
    migrations = for %{kind: :migration, module: mod} <- entries, do: mod

    with {:ok, applied} <- read_applied(migrations) do
      floor = Enum.max(disk_versions(state) ++ applied, fn -> 0 end)

      {placements, _next} =
        Enum.map_reduce(entries, floor + 1, fn %{module: mod} = entry, next ->
          cond do
            entry.kind == :module ->
              {{mod, {named_path(state, mod, :module), nil}}, next}

            version = migration_version(state, mod) ->
              {{mod, {named_path(state, mod, :migration, version), version}}, next}

            true ->
              {{mod, {named_path(state, mod, :migration, next), next}}, next + 1}
          end
        end)

      {:ok, Map.new(placements)}
    end
  end

  # `Macro.underscore/1` folds case, so `HTTPClient` and `HttpClient`
  # share a file, as can a hand-made file and a module named like it.
  # A second module placed at a taken path would replace the holder's
  # source and lose it at the next boot. A quarantined file is the
  # unit of deletion, so it never blocks one of its own modules.
  defp check_paths(state, entries, placements) do
    {errors, _claimed} =
      Enum.flat_map_reduce(entries, %{}, fn %{module: mod}, claimed ->
        {path, _version} = Map.fetch!(placements, mod)

        defined = for {other, ^path} <- state.modules, other != mod, do: other

        quarantined =
          for %{file: ^path, modules: mods} <- state.quarantined,
              mod not in mods,
              other <- mods,
              do: other

        holders = defined ++ quarantined

        error =
          case {Map.fetch(claimed, path), holders} do
            {{:ok, other}, _holders} -> [shared_path_error(state, other, mod, path)]
            {:error, []} -> []
            {:error, holders} -> [held_path_error(state, mod, holders, path)]
          end

        {error, Map.put(claimed, path, mod)}
      end)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "\n")}
    end
  end

  defp held_path_error(state, mod, holders, path) do
    "#{inspect(mod)} would be stored at #{relative(state, path)}, which already holds " <>
      "#{Enum.map_join(holders, ", ", &inspect/1)}. Choose another name for " <>
      "#{inspect(mod)}: #{@path_rule}"
  end

  defp shared_path_error(state, first, second, path) do
    "#{inspect(first)} and #{inspect(second)} would both be stored at " <>
      "#{relative(state, path)}. Choose another name for one of them: #{@path_rule}"
  end

  # The `use` line decided the placement; the compiled module is the
  # proof. A module that became a migration some other way, or says
  # `use Ecto.Migration` and compiles into something else, would be
  # filed under the wrong root.
  defp check_kinds(entries) do
    entries
    |> Enum.reject(fn %{module: mod, kind: kind} ->
      function_exported?(mod, :__migration__, 0) == (kind == :migration)
    end)
    |> case do
      [] ->
        :ok

      mismatched ->
        {:error,
         Enum.map_join(mismatched, "\n", fn %{module: mod, kind: kind} ->
           case kind do
             :module ->
               "#{inspect(mod)} compiled as a migration without saying so — write " <>
                 "`use Ecto.Migration` directly in the module, so it is filed under migrations/"

             :migration ->
               "#{inspect(mod)} says `use Ecto.Migration` but did not compile as a " <>
                 "migration — keep the `use` line for migrations only"
           end
         end)}
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

  defp named_path(state, mod, kind, version \\ nil),
    do: Path.join(state.code_dir, Entry.named_path(mod, kind, version))

  # Commit and rollback

  defp commit(state, run) do
    diffs = replace_diffs(state, run)
    compiled = compiled_records()
    persist(state, run, compiled)
    state = committed_state(state, run, compiled)
    publish(state)
    audit(state, run, diffs)
    {:ok, summary(run, state, diffs), state}
  end

  # What a replace did to the module's functions, read before the
  # staged text moves over the old file, which is the last moment the
  # old source exists. A quarantined module's old source is its
  # quarantined file, whatever else that file holds.
  defp replace_diffs(state, run) do
    Map.new(run.replaced, fn mod ->
      {^mod, staging_file} = List.keyfind(run.staged, mod, 0)
      {:ok, old_file} = source_file(state, mod)
      {mod, Source.diff(File.read!(old_file), File.read!(staging_file))}
    end)
  end

  defp persist(state, run, compiled) do
    Enum.each(run.staged, fn {mod, staging_file} ->
      {path, _version} = Map.fetch!(run.placements, mod)
      File.mkdir_p!(Path.dirname(path))
      File.rename!(staging_file, path)
      remove_divergent_source(state, mod, path)
    end)

    Enum.each(compiled, fn {:compiled, mod, _file, binary} ->
      File.write!(beam_path(state, mod), binary)
    end)

    clear_staging(state)
  end

  defp committed_state(state, run, compiled) do
    modules =
      Enum.reduce(run.entry_modules, state.modules, fn mod, modules ->
        {path, _version} = Map.fetch!(run.placements, mod)
        Map.put(modules, mod, path)
      end)

    owners = compile_owners(state, run.entry_modules)
    known = known_in_run(state, run)

    compiled_mods =
      for {:compiled, mod, _file, _binary} <- compiled, not Map.has_key?(owners, mod), do: mod

    quarantined =
      Enum.reject(state.quarantined, fn entry ->
        Enum.any?(entry.modules, &(&1 in run.entry_modules))
      end)

    %{
      state
      | modules: modules,
        deps: merge_deps(state, compiled_mods, owners, known),
        calls: merge_calls(state, compiled_mods, owners, known),
        generated: replace_generated(state, compiled_mods, owners),
        quarantined: quarantined
    }
  end

  defp audit(state, run, diffs) do
    case run.verb do
      :define ->
        Audit.record_define(state.code_dir, run.entry_modules, run.replaced, diffs, run.principal)

      :patch ->
        Audit.record_patch(state.code_dir, run.entry_modules, diffs, run.principal)
    end
  end

  # source_file/1 over the server's own state, which the table is
  # published from.
  defp source_file(state, mod) do
    case Map.fetch(state.modules, mod) do
      {:ok, source_file} ->
        {:ok, source_file}

      :error ->
        case Enum.find(state.quarantined, &(mod in &1.modules)) do
          %{file: file} -> {:ok, file}
          nil -> :error
        end
    end
  end

  # Neither define nor patch applies a migration, and the moment of
  # definition is when the cue to run it matters.
  defp head(run, mod) do
    verb_part =
      case run.verb do
        :define ->
          "Defined #{inspect(mod)} (#{if mod in run.replaced, do: "replaced", else: "new"})"

        :patch ->
          "Patched #{inspect(mod)}"
      end

    case Map.fetch!(run.placements, mod) do
      {_path, nil} ->
        verb_part

      {_path, version} ->
        "#{verb_part} — migration #{version}, pending: run Host.Migrator.migrate()"
    end
  end

  # A replace and a patch say what they did to the module's
  # functions, since a function lost in a re-emission is otherwise
  # lost silently.
  defp summary(run, state, diffs) do
    lines =
      Enum.flat_map(run.entry_modules, fn mod ->
        head = head(run, mod)

        case diffs do
          %{^mod => diff} -> [head | Source.render_diff(diff)]
          _new -> [head]
        end
      end)

    lines =
      case run.dependents do
        [] ->
          lines

        dependents ->
          lines ++ ["Recompiled dependents: #{Enum.map_join(dependents, ", ", &inspect/1)}"]
      end

    caller_lines = runtime_caller_lines(state, run.replaced, run.entry_modules)
    Enum.join(lines ++ caller_lines, "\n")
  end

  # Callers outside the entries survive a replace unrecompiled, since
  # their calls resolve at runtime, so the summary names them and
  # what they call, as fact: whether the replacement still suits them
  # is the agent's judgment.
  defp runtime_caller_lines(state, replaced, entry_modules) do
    callers =
      for {caller, targets} <- state.calls,
          caller not in entry_modules,
          {callee, fas} <- targets,
          owner = owner(state.generated, callee),
          owner in replaced,
          fa <- fas,
          do: {caller, render_call(owner, callee, fa)}

    case callers do
      [] ->
        []

      _some ->
        rendered =
          callers
          |> Enum.group_by(fn {caller, _fa} -> caller end, fn {_caller, fa} -> fa end)
          |> Enum.sort_by(fn {caller, _fas} -> inspect(caller) end)
          |> Enum.map_join(", ", fn {caller, fas} ->
            "#{inspect(caller)} (#{fas |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")})"
          end)

        ["Note: called at runtime by #{rendered}"]
    end
  end

  # A call to a generated module is a call into its owner's file, so
  # it breaks when the owner is replaced and the module or function
  # goes.
  defp broken_callers(calls, replaced, generated) do
    for {caller, targets} <- calls,
        {callee, fas} <- targets,
        owner = owner(generated, callee),
        owner in replaced,
        {f, a} <- fas,
        not function_exported?(callee, f, a),
        do: {caller, owner, callee, f, a}
  end

  defp render_broken_callers(breaks) do
    breaks
    |> Enum.group_by(fn {caller, owner, _callee, _f, _a} -> {caller, owner} end, fn
      {_caller, _owner, callee, f, a} -> {callee, f, a}
    end)
    |> Enum.sort_by(fn {{caller, owner}, _calls} -> {inspect(owner), inspect(caller)} end)
    |> Enum.map_join("\n", fn {{caller, owner}, calls} ->
      calls =
        calls
        |> Enum.sort()
        |> Enum.map_join(", ", fn {callee, f, a} -> "#{inspect(callee)}.#{f}/#{a}" end)

      "replacing #{inspect(owner)} broke its caller #{inspect(caller)} — " <>
        "#{inspect(caller)} calls #{calls}, which the replacement no longer defines. " <>
        "Nothing was changed. Update #{inspect(caller)} in the same call, or keep #{calls}."
    end)
  end

  # A call into the module itself reads as its function; one into a
  # module it generates names that module.
  defp render_call(owner, owner, {f, a}), do: "#{f}/#{a}"
  defp render_call(_owner, callee, {f, a}), do: "#{inspect(callee)}.#{f}/#{a}"

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

  # Besides the new entries, the compile may have loaded modules no
  # previous version had, an embedded schema a replace renamed, and
  # those go too.
  defp rollback(state, run) do
    compiled = for {:compiled, mod, _file, _binary} <- compiled_records(), do: mod
    Enum.each(Enum.uniq(run.new ++ compiled) -- run.previous, &remove_module/1)

    Enum.each(run.previous, fn mod ->
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

    clear_staging(state)
    :ok
  end

  defp remove_module(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
  end

  # Every diagnostic locates by the path its file will be stored at and
  # quotes the line. The compiler closes a failed batch with a summary
  # diagnostic at position 0 naming the staging file, which says
  # nothing the located ones do not; it is dropped, unless it is all
  # there is.
  defp render_compile_error(state, diagnostics, render, replaced, dependents) do
    dependent_files = Map.new(dependents, fn mod -> {Map.fetch!(state.modules, mod), mod} end)

    located =
      case Enum.reject(diagnostics, &summary_diagnostic?/1) do
        [] -> diagnostics
        some -> some
      end

    case Enum.find(located, &Map.has_key?(dependent_files, &1.file)) do
      nil ->
        Enum.map_join(located, "\n", &render_diagnostic(&1, render))

      diagnostic ->
        dependent = Map.fetch!(dependent_files, diagnostic.file)
        replaced_names = Enum.map_join(replaced, ", ", &inspect/1)

        "replacing #{replaced_names} broke its dependent #{inspect(dependent)} — " <>
          "#{render_diagnostic(diagnostic, render)}\nNothing was changed. " <>
          "Update #{inspect(dependent)} in the same call, or keep #{replaced_names} compatible."
    end
  end

  defp summary_diagnostic?(diagnostic) do
    diag_line(diagnostic) == 0 and diagnostic.message =~ "cannot compile module"
  end

  defp render_diagnostic(diagnostic, %{context: context, locators: locators} = render) do
    {line, message} = line_and_message(diagnostic, render)

    case Map.get(locators, diagnostic.file) do
      nil ->
        "line #{line}: #{message}"

      %{locator: locator, source: source, label: label} ->
        labelled(label, Scanner.locate(source, locator, line, message, context: context))
    end
  end

  defp labelled(nil, message), do: message
  defp labelled(label, message), do: "#{label}: #{message}"

  defp diag_line(%{position: {line, _column}}), do: line
  defp diag_line(%{position: line}) when is_integer(line), do: line
  defp diag_line(_diagnostic), do: 0

  # An exception raised while a module body runs arrives at line 0,
  # its trace formatted into the message and naming the staged copy.
  # The line is taken from the trace's frame in the failing file, and
  # the trace is formatted again up to that frame, as Elixir's own
  # message is, with each file under the code dir as its locator.
  defp line_and_message(
         %{stacktrace: [_ | _] = stacktrace, details: {kind, reason}} = diagnostic,
         render
       ) do
    if diag_line(diagnostic) == 0 do
      file = Path.expand(diagnostic.file)
      {inner, from} = Enum.split_while(stacktrace, &(frame_file(&1) != file))

      line =
        case from do
          [{_mod, _fun, _arity, location} | _rest] -> Keyword.get(location, :line, 0)
          [] -> 0
        end

      frames = Enum.map(inner ++ Enum.take(from, 1), &locate_frame(&1, render))
      {line, kind |> Exception.format(reason, frames) |> String.trim_trailing()}
    else
      {diag_line(diagnostic), diagnostic.message}
    end
  end

  defp line_and_message(diagnostic, _render), do: {diag_line(diagnostic), diagnostic.message}

  defp frame_file({_mod, _fun, _arity, location}) when is_list(location) do
    if file = location[:file], do: Path.expand(to_string(file))
  end

  defp frame_file(_frame), do: nil

  defp locate_frame({mod, fun, arity, location} = frame, render) when is_list(location) do
    case frame_file(frame) do
      nil ->
        frame

      file ->
        {mod, fun, arity, Keyword.put(location, :file, frame_locator(file, location, render))}
    end
  end

  defp locate_frame(frame, _render), do: frame

  # The staging dir mirrors the code dir, so a staged file's locator is
  # its path under either. A defined module's beam records the staged
  # copy it was compiled from, so its frames are rewritten the same way.
  defp frame_locator(file, location, %{staging_dir: staging_dir, code_dir: code_dir}) do
    cond do
      String.starts_with?(file, staging_dir <> "/") ->
        file |> Path.relative_to(staging_dir) |> String.to_charlist()

      String.starts_with?(file, code_dir <> "/") ->
        file |> Path.relative_to(code_dir) |> String.to_charlist()

      true ->
        location[:file]
    end
  end

  # Elixir only warns when clauses of one function are separated by
  # other definitions, and the module compiles and runs. The warning
  # is refused here because a function's clauses must be one
  # contiguous block for the patch tool to select them by name and
  # arity. The sibling warning for the same name at another arity is
  # left alone: different arities are different functions.
  @scattered_clauses ~r/\Aclauses with the same name and arity \(number of arguments\) should be grouped together, "(?<fun>[^"]+)" was previously defined \(.*:(?<line>\d+)\)\z/

  defp check_grouped(warnings, locators) do
    case scattered_clauses(warnings) do
      [] ->
        :ok

      scattered ->
        {:error,
         Enum.map_join(scattered, "\n", fn {file, _fun, _earlier, _later} = clause ->
           %{locator: locator, label: label} = Map.fetch!(locators, file)
           labelled(label, render_scattered(clause, locator))
         end)}
    end
  end

  defp scattered_clauses(warnings) do
    Enum.flat_map(warnings, fn warning ->
      case Regex.named_captures(@scattered_clauses, warning.message) do
        %{"fun" => fun, "line" => earlier} ->
          [{warning.file, fun, String.to_integer(earlier), diag_line(warning)}]

        nil ->
          []
      end
    end)
  end

  defp render_scattered({_file, fun, earlier, later}, form) do
    "#{fun} (#{form}:#{later}) is separated from its earlier clause (#{form}:#{earlier}) " <>
      "by other definitions — group the clauses of a function together"
  end

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
        cond do
          owner = Map.get(state.generated, mod) ->
            generated_error(state, mod, owner, "remove #{inspect(owner)}, and it goes too")

          Code.ensure_loaded?(mod) ->
            "Host.Code.remove removes defined modules only — #{inspect(mod)} is part of " <>
              "your beamlet."

          true ->
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

        calls =
          for {callee, fas} <- Map.get(state.calls, mod, %{}),
              owner(state.generated, callee) == target,
              fa <- fas,
              do: render_call(target, callee, fa)

        uses =
          case {Enum.sort(calls), compile?} do
            {[], false} ->
              nil

            {[], true} ->
              "depends on it at compile time"

            {calls, false} ->
              "calls #{Enum.join(calls, ", ")}"

            {calls, true} ->
              "calls #{Enum.join(calls, ", ")} and depends on it at compile time"
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
    unloaded = with_generated(state, defined)

    Enum.each(defined, fn mod -> File.rm(Map.fetch!(state.modules, mod)) end)

    Enum.each(unloaded, fn mod ->
      remove_module(mod)
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
        generated: Map.drop(state.generated, unloaded),
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
    %{
      state
      | modules: %{},
        deps: %{},
        calls: %{},
        generated: %{},
        quarantined: Enum.reverse(quarantined)
    }
  end

  defp boot_loop(state, files, quarantined) do
    clear_records()
    file_modules = Map.new(files, &{&1, parse_modules(&1)})

    # Quarantined names stay in the defined set so edges to them
    # survive a later recovery.
    defined =
      (file_modules |> Map.values() |> List.flatten()) ++
        Enum.flat_map(quarantined, & &1.modules)

    ctx = %{roots: MapSet.new(files), defined: MapSet.new(defined), ebin: ebin(state)}

    result =
      with_compiler_env(ctx, fn ->
        Kernel.ParallelCompiler.compile(files,
          return_diagnostics: true,
          dest: state.ebin_dir,
          each_module: &capture/3
        )
      end)

    case boot_errors(state, files, result) do
      errors when map_size(errors) == 0 ->
        finalize_boot(state, file_modules, quarantined)

      errors ->
        entries = quarantine_files(state, file_modules, errors)
        boot_loop(state, files -- Map.keys(errors), Enum.reverse(entries) ++ quarantined)
    end
  end

  # Each file the round must quarantine, with the error it carries.
  defp boot_errors(state, _files, {:ok, _modules, %{compile_warnings: warnings}}) do
    warnings
    |> scattered_clauses()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {file, scattered} ->
      {file, Enum.map_join(scattered, "; ", &render_scattered(&1, relative(state, file)))}
    end)
  end

  defp boot_errors(_state, files, {:error, diagnostics, _warnings}) do
    bad_files =
      diagnostics
      |> Enum.map(& &1.file)
      |> Enum.uniq()
      |> Enum.filter(&(&1 in files))

    # An unattributable failure quarantines everything remaining
    # rather than looping forever.
    bad_files = if bad_files == [], do: files, else: bad_files
    Map.new(bad_files, &{&1, boot_error(diagnostics, &1)})
  end

  defp quarantine_files(state, file_modules, errors) do
    entries =
      errors
      |> Enum.sort()
      |> Enum.map(fn {file, error} ->
        Logger.warning("code boot: quarantined #{relative(state, file)}: #{error}")
        %{file: file, modules: Map.fetch!(file_modules, file), error: error}
      end)

    purge_captured(Map.keys(errors))
    entries
  end

  # The defined set is what the files declare at top level, as at
  # define; everything else compiled is generated.
  defp finalize_boot(state, file_modules, quarantined) do
    compiled = compiled_records()

    Enum.each(compiled, fn {:compiled, mod, _file, binary} ->
      File.write!(beam_path(state, mod), binary)
    end)

    prune_ebin(state, Enum.map(compiled, fn {:compiled, mod, _file, _binary} -> mod end))

    modules =
      for {:compiled, mod, file, _binary} <- compiled,
          mod in Map.get(file_modules, file, []),
          into: %{},
          do: {mod, file}

    owners = generated_owners(&Map.has_key?(modules, &1))
    state = %{state | modules: modules, generated: owners}
    known = MapSet.new(Map.keys(modules) ++ Enum.flat_map(quarantined, & &1.modules))

    %{
      state
      | deps: merge_deps(%{state | deps: %{}}, Map.keys(modules), owners, known),
        calls: merge_calls(%{state | calls: %{}}, Map.keys(modules), owners, known),
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

  # An empty root set keeps the tracer out of it: nothing in a derived
  # artifact is an edge between defined modules.
  defp run_compile_artifact(source, file) do
    ctx = %{roots: MapSet.new(), defined: MapSet.new(), ebin: []}
    quoted = source.()
    {:ok, with_compiler_env(ctx, fn -> Code.compile_quoted(quoted, file) end)}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  # A module body that raises partway through a compile unloads the
  # module's previous version, so the last good binaries go back in.
  # With none, the module loads again from its compiled-in version.
  defp restore_artifact(compiled, file) do
    Enum.each(compiled, fn {mod, binary} ->
      :code.purge(mod)
      {:module, ^mod} = :code.load_binary(mod, String.to_charlist(file), binary)
    end)
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

  # A generated module's edges and calls are its owner's: it compiles
  # from the owner's file, so recompiling that file is what refreshes
  # it. As a target it stands for its owner too, since replacing or
  # removing the owner is what changes it: an edge goes to the owner,
  # and a call keeps the module it names, read through its owner. The
  # tracer records more than it keeps (Beamlet.Code.Tracer), so a
  # record survives only when its target resolves to a defined module.
  defp merge_deps(state, compiled_mods, owners, known) do
    generated = Map.merge(state.generated, owners)

    by_source =
      __MODULE__
      |> :ets.match_object({:edge, :_, :_})
      |> Enum.map(fn {:edge, source, target} ->
        {owner(generated, source), owner(generated, target)}
      end)
      |> Enum.filter(fn {source, target} ->
        source != target and MapSet.member?(known, target)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    new_deps = Map.new(compiled_mods, fn mod -> {mod, Enum.uniq(Map.get(by_source, mod, []))} end)
    Map.merge(state.deps, new_deps)
  end

  defp merge_calls(state, compiled_mods, owners, known) do
    generated = Map.merge(state.generated, owners)

    by_source =
      __MODULE__
      |> :ets.match_object({:call, :_, :_, :_, :_})
      |> Enum.map(fn {:call, source, target, f, a} ->
        {owner(generated, source), target, {f, a}}
      end)
      |> Enum.filter(fn {source, target, _fa} ->
        owner = owner(generated, target)
        source != owner and MapSet.member?(known, owner)
      end)
      |> Enum.group_by(&elem(&1, 0))

    new_calls =
      Map.new(compiled_mods, fn mod ->
        targets =
          by_source
          |> Map.get(mod, [])
          |> Enum.group_by(fn {_source, target, _fa} -> target end, &elem(&1, 2))
          |> Map.new(fn {target, fas} -> {target, fas |> Enum.uniq() |> Enum.sort()} end)

        {mod, targets}
      end)

    Map.merge(state.calls, new_calls)
  end

  # Generated modules

  # A file declares its modules at top level; a macro can create more
  # as it compiles, an inline embedded schema or a derived protocol
  # implementation. Those are generated: loaded, with beams, but not
  # defined, so never removable or definable on their own, and they
  # go with their owner, a module the same file declares. Each maps
  # to its owner.
  defp generated_owners(declared?) do
    compiled_records()
    |> Enum.group_by(fn {:compiled, _mod, file, _binary} -> file end, &elem(&1, 1))
    |> Enum.flat_map(fn {_file, mods} ->
      case Enum.split_with(mods, declared?) do
        {[], _orphans} -> []
        {[owner | _declared], generated} -> Enum.map(generated, &{&1, owner})
      end
    end)
    |> Map.new()
  end

  defp compile_owners(state, entry_modules) do
    generated_owners(&(&1 in entry_modules or Map.has_key?(state.modules, &1)))
  end

  # A recompiled file's generated modules are the ones this compile
  # produced. Any it no longer produces, an embed renamed or dropped,
  # are unloaded and their beams deleted.
  defp replace_generated(state, compiled_mods, owners) do
    stale =
      for {mod, owner} <- state.generated,
          owner in compiled_mods,
          not Map.has_key?(owners, mod),
          do: mod

    Enum.each(stale, fn mod ->
      remove_module(mod)
      File.rm(beam_path(state, mod))
    end)

    state.generated |> Map.drop(stale) |> Map.merge(owners)
  end

  defp owner(generated, mod), do: Map.get(generated, mod, mod)

  defp with_generated(state, modules) do
    modules ++ for {mod, owner} <- state.generated, owner in modules, do: mod
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

  defp known_in_run(state, run) do
    MapSet.union(known_module_names(state), MapSet.new(run.entry_modules))
  end

  # Sources

  # A file that does not parse still names its modules on its
  # `defmodule` lines, and reading them is what keeps a torn hand edit
  # listed as quarantined and readable by line range, rather than
  # vanishing from the beamlet.
  defp parse_modules(file) do
    case File.read(file) do
      {:ok, code} ->
        case Code.string_to_quoted(code) do
          {:ok, ast} ->
            ast
            |> Entry.block_forms()
            |> Enum.flat_map(fn
              {:defmodule, _meta, [{:__aliases__, _, parts} | _rest]} ->
                if is_list(parts) and Enum.all?(parts, &is_atom/1),
                  do: [Module.concat(parts)],
                  else: []

              _other ->
                []
            end)

          {:error, _reason} ->
            ~r/^\s*defmodule\s+([A-Z][\w.]*)/m
            |> Regex.scan(code, capture: :all_but_first)
            |> Enum.map(fn [name] -> Module.concat([name]) end)
        end

      {:error, _reason} ->
        []
    end
  end

  # The staging dir mirrors the code dir: each entry is staged at the
  # path it will be stored at, so the compiled file's line numbers are
  # the stored file's. The staged text moves into place at commit.
  defp write_staging(state, entries, placements) do
    Enum.map(entries, fn %{module: mod, source: source} ->
      {path, _version} = Map.fetch!(placements, mod)
      staging_file = Path.join(state.staging_dir, relative(state, path))
      File.mkdir_p!(Path.dirname(staging_file))
      File.write!(staging_file, source)
      {mod, staging_file}
    end)
  end

  defp clear_staging(state), do: File.rm_rf!(state.staging_dir)

  defp beam_path(state, mod), do: Path.join(state.ebin_dir, "#{mod}.beam")

  defp ebin(state), do: String.to_charlist(state.ebin_dir <> "/")

  defp relative(state, file), do: Path.relative_to(file, state.code_dir)
end
