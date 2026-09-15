defmodule Beamlet.Policy.Default do
  # The curation record: every name-based ruling of the policy Beamlet
  # ships lives in this module's data, and nowhere else. Pure data and
  # accessors; composition and enforcement live in Beamlet.Policy. The
  # coverage test in default_test.exs proves every documented platform
  # module appears in exactly one of these maps, and the golden fixture
  # pins the composed table. The moduledoc below is rendered from the
  # data at compile time, so the printed record cannot drift from it.

  # ── Grants ────────────────────────────────────────────────────────

  # Partial grants carry their slice rationale: Function.capture
  # builds funs from names (dynamic dispatch); IO is granted for
  # output only (device-directed IO reaches arbitrary processes);
  # Path is pure string manipulation, safe because Host.FS re-checks
  # every path it receives, except wildcard, which touches the real
  # filesystem; System keeps its clock/VM introspection and loses
  # shell, env, and lifecycle control.
  @elixir %{
    Access => :all,
    Atom => :all,
    Base => :all,
    Bitwise => :all,
    Calendar => :all,
    Calendar.ISO => :all,
    Calendar.TimeZoneDatabase => :all,
    Calendar.UTCOnlyTimeZoneDatabase => :all,
    Collectable => :all,
    Date => :all,
    Date.Range => :all,
    DateTime => :all,
    Duration => :all,
    Enum => :all,
    Enumerable => :all,
    Exception => :all,
    Float => :all,
    Function => {:except, [capture: 3]},
    IO =>
      {:only,
       [
         puts: 1,
         warn: 1,
         inspect: 1,
         inspect: 2,
         iodata_to_binary: 1,
         iodata_length: 1,
         chardata_to_string: 1
       ]},
    IO.ANSI => :all,
    Inspect => :all,
    Inspect.Algebra => :all,
    Inspect.Opts => :all,
    Integer => :all,
    JSON => :all,
    JSON.Encoder => :all,
    Kernel =>
      {:except,
       [
         apply: 2,
         apply: 3,
         spawn: 1,
         spawn: 3,
         spawn_link: 1,
         spawn_link: 3,
         spawn_monitor: 1,
         spawn_monitor: 3,
         send: 2,
         exit: 1
       ]},
    Keyword => :all,
    List => :all,
    List.Chars => :all,
    Map => :all,
    MapSet => :all,
    NaiveDateTime => :all,
    OptionParser => :all,
    Path => {:except, [wildcard: 1, wildcard: 2]},
    Range => :all,
    Record => :all,
    Regex => :all,
    Stream => :all,
    String => {:except, [to_atom: 1, to_existing_atom: 1]},
    String.Chars => :all,
    System =>
      {:only,
       [
         convert_time_unit: 3,
         endianness: 0,
         monotonic_time: 0,
         monotonic_time: 1,
         os_time: 0,
         os_time: 1,
         otp_release: 0,
         schedulers: 0,
         schedulers_online: 0,
         system_time: 0,
         system_time: 1,
         time_offset: 0,
         time_offset: 1,
         unique_integer: 0,
         unique_integer: 1,
         version: 0
       ]},
    Time => :all,
    Tuple => :all,
    URI => :all,
    Version => :all,
    Version.Requirement => :all
  }

  # Exception modules are inert structs plus message callbacks,
  # granted as a family and derived so a new Elixir exception never
  # goes stale in a manual list (the golden fixture still surfaces
  # each addition for review). Includes exceptions of denied
  # modules: rescuing File.Error does not grant File.
  @elixir_exceptions for mod <- Application.spec(:elixir, :modules),
                         Code.ensure_loaded?(mod),
                         function_exported?(mod, :__struct__, 0),
                         match?(%{__exception__: true}, mod.__struct__()),
                         do: mod

  # Erlang is gap-filling only: where Elixir covers the ground, the
  # Erlang module is not granted (recorded under not-granted below).
  # :erlang keeps term hashing and checksums; term_to_binary and
  # binary_to_term are denied both ways (binary_to_term constructs
  # atoms and funs, the String.to_atom posture).
  @erlang %{
    :binary => :all,
    :crypto => :all,
    :erlang =>
      {:only,
       [
         adler32: 1,
         adler32: 2,
         crc32: 1,
         crc32: 2,
         external_size: 1,
         external_size: 2,
         phash2: 1,
         phash2: 2
       ]},
    :graph => :all,
    :math => :all,
    :queue => :all,
    :rand => :all,
    :zlib => :all,
    :zstd => :all
  }

  # The web-authoring surface: the modules agents literally write
  # against when authoring LiveViews and controllers. Curated grants,
  # not a package grant, because the Phoenix family ships machinery
  # (endpoints, routers, sockets) agents have no business calling, and
  # deny-by-default covers everything not named here. Carve-outs are
  # the functions that reach the real filesystem: embed_templates
  # reads template files at compile time, send_download's {:file, _}
  # flavor and send_file serve arbitrary paths.
  @web %{
    Phoenix.Component => {:except, [embed_templates: 1, embed_templates: 2]},
    Phoenix.Controller => {:except, [send_download: 2, send_download: 3]},
    Phoenix.Flash => :all,
    Phoenix.HTML => :all,
    Phoenix.LiveComponent => :all,
    Phoenix.LiveView => :all,
    Phoenix.LiveView.AsyncResult => :all,
    Phoenix.LiveView.JS => :all,
    Phoenix.LiveView.Socket => :all,
    Plug.Conn => {:except, [send_file: 3, send_file: 4, send_file: 5]}
  }

  # The data-authoring surface: the Ecto modules agents write
  # schemas, changesets, queries and migrations against. Ecto.Query.API
  # has no callable functions; it documents the names used inside
  # queries. Ecto.Migration loses execute_file, which reads SQL from a
  # real path. Ecto.Repo itself is not granted: Host.Repo is the one
  # repo agent code reaches, and the adapters below it carry signage.
  @data %{
    Ecto => :all,
    Ecto.Changeset => :all,
    Ecto.Enum => :all,
    Ecto.Migration => {:except, [execute_file: 1, execute_file: 2]},
    Ecto.Multi => :all,
    Ecto.ParameterizedType => :all,
    Ecto.Query => :all,
    Ecto.Query.API => :all,
    Ecto.Schema => :all,
    Ecto.Type => :all,
    Ecto.UUID => :all
  }

  # Ecto's exceptions, granted as a family like Elixir's: an agent
  # rescues Ecto.NoResultsError or Ecto.ConstraintError, and rescuing
  # grants nothing else.
  @data_exceptions for app <- [:ecto, :ecto_sql],
                       _ = Application.load(app),
                       mod <- Application.spec(app, :modules) || [],
                       Code.ensure_loaded?(mod),
                       function_exported?(mod, :__struct__, 0),
                       match?(%{__exception__: true}, mod.__struct__()),
                       do: mod

  # The host stdlib, one row per module as each lands. Host.Repo:
  # denied are the repo's process controls (put_dynamic_repo
  # redirects every call to any running repo by name, the system repo
  # included; start_link, stop and disconnect_all touch the pool). Raw
  # SQL is granted: the agent database is the agent's to break, and
  # the one statement that reached past it, ATTACH DATABASE, is refused
  # by the SQLite authorizer on every connection
  # (Beamlet.SQLiteAuthorizer).
  @host %{
    Host.Repo =>
      {:except,
       [
         put_dynamic_repo: 1,
         start_link: 0,
         start_link: 1,
         stop: 0,
         stop: 1,
         disconnect_all: 1,
         disconnect_all: 2
       ]}
  }

  # Packages the beamlet ships for agent code, expanded into
  # per-module entries when the table is built, @moduledoc false
  # modules excluded. Jason rides alongside Elixir's own JSON module:
  # models that predate JSON reach for Jason by training prior, and
  # turning them away teaches nothing.
  @packages [:jason, :req]

  # The language's self-reference: __MODULE__ is always the module
  # being defined, granted by construction. Keyed by the sentinel the
  # scanner resolves it to; not a platform module, so outside the
  # coverage walk.
  @language %{:__MODULE__ => :all}

  @granted @elixir
           |> Map.merge(Map.new(@elixir_exceptions, &{&1, :all}))
           |> Map.merge(@erlang)
           |> Map.merge(@web)
           |> Map.merge(@data)
           |> Map.merge(Map.new(@data_exceptions, &{&1, :all}))
           |> Map.merge(@host)
           |> Map.merge(@language)

  # ── Signage: denials that teach ───────────────────────────────────
  #
  # One shared teaching message per category, appended to the
  # scanner's error copy and rendered by Beamlet.Policy.render/1. Two
  # levels, nothing deeper: a module or function match here, or the
  # generic denial.

  @categories [
    :fs,
    :concurrency,
    :confidentiality,
    :shell,
    :eval,
    :dynamic,
    :routing,
    :pubsub,
    :data,
    :migrations
  ]

  @category_copy %{
    fs: "Host.FS provides scoped file access",
    concurrency:
      "concurrency primitives are not available to agent code yet — " <>
        "supervised processes are planned",
    confidentiality:
      "environment and application config are not readable from agent code — " <>
        "they may hold credentials",
    shell: "shell and OS access are not available to agent code",
    eval:
      "runtime code loading, evaluation, and macro machinery are not " <>
        "available to agent code — durable code goes through define",
    dynamic: "dynamic name construction and dispatch are not permitted",
    routing: "the URL surface is managed through Host.Router, not router modules",
    pubsub: "publish/subscribe goes through Host.PubSub",
    migrations: "migrations are run through Host.Migrator",
    data: "the agent database is reached through Host.Repo; raw SQL is Host.Repo.query!(sql)"
  }

  @signage %{
    # File access: Host.FS is the safe alternative.
    File => :fs,
    File.Stream => :fs,
    File.Stat => :fs,
    :file => :fs,
    :filelib => :fs,
    :file_sorter => :fs,
    :erl_tar => :fs,
    :zip => :fs,
    :disk_log => :fs,
    # Process primitives and process-owned state: the door supervised
    # processes will open, not a wall.
    Process => :concurrency,
    Task => :concurrency,
    Task.Supervisor => :concurrency,
    GenServer => :concurrency,
    GenEvent => :concurrency,
    Agent => :concurrency,
    Node => :concurrency,
    Port => :concurrency,
    Supervisor => :concurrency,
    DynamicSupervisor => :concurrency,
    PartitionSupervisor => :concurrency,
    Registry => :concurrency,
    StringIO => :concurrency,
    :ets => :concurrency,
    :dets => :concurrency,
    :timer => :concurrency,
    :gen_server => :concurrency,
    :gen_statem => :concurrency,
    :gen_event => :concurrency,
    :gen_fsm => :concurrency,
    :proc_lib => :concurrency,
    :sys => :concurrency,
    :atomics => :concurrency,
    :counters => :concurrency,
    :persistent_term => :concurrency,
    :digraph => :concurrency,
    :digraph_utils => :concurrency,
    # Environment and application config carry credentials.
    Application => :confidentiality,
    Config => :confidentiality,
    Config.Provider => :confidentiality,
    Config.Reader => :confidentiality,
    :application => :confidentiality,
    :os => :shell,
    # Code loading, evaluation, and macro machinery.
    Code => :eval,
    Code.Fragment => :eval,
    Macro => :eval,
    Module => :eval,
    :code => :eval,
    :erl_eval => :eval,
    # Web machinery around the granted authoring surface: routers and
    # endpoints belong to the beamlet, PubSub is reached through the
    # stdlib so agents never name the server, and Phoenix.Token signs
    # with the endpoint secret.
    Phoenix.Router => :routing,
    Phoenix.Endpoint => :routing,
    Phoenix.LiveView.Router => :routing,
    Plug.Router => :routing,
    Phoenix.PubSub => :pubsub,
    Phoenix.Token => :confidentiality,
    # The repo behaviour and everything beneath it: a granted
    # Ecto.Repo would let an agent open any database file, and the
    # adapters and driver are raw-SQL surfaces. Ecto.Migrator runs
    # migrations against any repo; Host.Migrator runs the agent's
    # against the agent database.
    Ecto.Migrator => :migrations,
    Ecto.Repo => :data,
    Ecto.Adapters.SQL => :data,
    Ecto.Adapters.SQL.Sandbox => :data,
    Ecto.Adapters.SQLite3 => :data,
    Exqlite => :data,
    Exqlite.Basic => :data,
    Exqlite.Connection => :data,
    Exqlite.Sqlite3 => :data
  }

  # Function-level hints for partially granted modules (and Kernel
  # locals). Keyed by name: the grant tables own arities, the hint
  # only has to teach.
  @signage_functions %{
    {Kernel, :apply} => :dynamic,
    {Kernel, :spawn} => :concurrency,
    {Kernel, :spawn_link} => :concurrency,
    {Kernel, :spawn_monitor} => :concurrency,
    {Kernel, :send} => :concurrency,
    {Kernel, :exit} => :concurrency,
    {String, :to_atom} => :dynamic,
    {String, :to_existing_atom} => :dynamic,
    {Function, :capture} => :dynamic,
    {System, :get_env} => :confidentiality,
    {System, :fetch_env} => :confidentiality,
    {System, :fetch_env!} => :confidentiality,
    {System, :put_env} => :confidentiality,
    {System, :delete_env} => :confidentiality,
    {System, :cmd} => :shell,
    {System, :shell} => :shell,
    {:erlang, :term_to_binary} => :dynamic,
    {:erlang, :binary_to_term} => :dynamic,
    {Phoenix.Component, :embed_templates} => :fs,
    {Phoenix.Controller, :send_download} => :fs,
    {Plug.Conn, :send_file} => :fs,
    {Ecto.Migration, :execute_file} => :fs
  }

  # ── Not granted: denials with nothing to teach ────────────────────
  #
  # The rest of the walk: denied by absence with the generic error
  # copy, the reason recorded here so the coverage test can prove the
  # walk exhaustive and future revisits can read why.

  @not_granted [
    {"an Elixir module covers the same ground",
     [
       :argparse,
       :base64,
       :calendar,
       :dict,
       :filename,
       :io_ansi,
       :io_lib,
       :json,
       :lists,
       :maps,
       :orddict,
       :proplists,
       :random,
       :re,
       :string,
       :unicode,
       :uri_string
     ]},
    {"functional collections declined until reached for",
     [:array, :gb_sets, :gb_trees, :ordsets, :sets, :sofs]},
    {"reads or writes the real filesystem", [:beam_lib, :wrap_log_reader]},
    {"process machinery, distribution, and node management, until supervised processes arrive",
     [
       :auth,
       :data_publisher,
       :erl_epmd,
       :erpc,
       :global,
       :global_group,
       :heart,
       :net_adm,
       :net_kernel,
       :peer,
       :pg,
       :pool,
       :rpc,
       :seq_trace,
       :slave,
       :supervisor,
       :supervisor_bridge,
       :trace
     ]},
    {"raw network access; Req carries the HTTP story",
     [:gen_sctp, :gen_tcp, :gen_udp, :inet, :inet_res, :net, :socket]},
    {"parsing, evaluation, and compilation of code",
     [
       :c,
       :epp,
       :erl_boot_server,
       :erl_ddll,
       :erl_expand_records,
       :erl_lint,
       :erl_parse,
       :erl_pp,
       :erl_scan,
       :ms_transform,
       :qlc,
       Kernel.ParallelCompiler,
       Macro.Env,
       Protocol
     ]},
    {"deprecated Elixir modules", [Behaviour, Dict, HashDict, HashSet, Set, Supervisor.Spec]},
    {"shell/tooling internals, or nothing to offer prelude-free agent code",
     [
       :edlin,
       :edlin_expand,
       :io,
       :erl_anno,
       :erl_debugger,
       :erl_error,
       :erl_features,
       :erl_internal,
       :erl_prim_loader,
       :error_handler,
       :error_logger,
       :escript,
       :init,
       :log_mf_h,
       :logger,
       :logger_disk_log_h,
       :logger_filters,
       :logger_formatter,
       :logger_handler,
       :logger_std_h,
       :records,
       :shell,
       :shell_default,
       :shell_docs,
       :win32reg,
       IO.Stream,
       Kernel.SpecialForms
     ]}
  ]

  # ── The rendered record ───────────────────────────────────────────

  @join_names fn modules ->
    modules |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join(", ")
  end

  @join_fas fn fas ->
    fas |> Enum.sort() |> Enum.map_join(", ", fn {fun, arity} -> "#{fun}/#{arity}" end)
  end

  @join_partials fn table, join_fas ->
    table
    |> Enum.filter(fn {_mod, entry} -> entry != :all end)
    |> Enum.sort_by(fn {mod, _entry} -> inspect(mod) end)
    |> Enum.map_join("\n", fn
      {mod, {:only, fas}} -> "  * `#{inspect(mod)}`: only #{join_fas.(fas)}"
      {mod, {:except, fas}} -> "  * `#{inspect(mod)}`: all except #{join_fas.(fas)}"
    end)
  end

  @rendered_signage Enum.map_join(
                      @categories,
                      "\n",
                      fn category ->
                        modules = for {mod, ^category} <- @signage, do: inspect(mod)

                        functions =
                          for {{mod, fun}, ^category} <- @signage_functions,
                              do: "#{inspect(mod)}.#{fun}"

                        names = Enum.sort(modules) ++ Enum.sort(functions)
                        "  * #{@category_copy[category]}:\n    #{Enum.join(names, ", ")}"
                      end
                    )

  @rendered_not_granted Enum.map_join(@not_granted, "\n", fn {reason, modules} ->
                          "  * #{reason}:\n    #{@join_names.(modules)}"
                        end)

  @moduledoc """
  The policy Beamlet ships: every name-based ruling of the curation
  pass, as data.

  `default` is what a token runs under when it names no policy and
  the base every declared policy builds on (`Beamlet.Policy`). This
  module is deliberately logic-free: `Beamlet.Policy` composes and
  enforces the rulings, the coverage test proves every documented
  platform module appears in exactly one map here, and the golden
  fixture pins the composed table. Everything below this paragraph
  is rendered from the data at compile time and cannot drift from
  it.

  ## Granted: Elixir

  #{@join_names.(for {mod, :all} <- @elixir, do: mod)}

  Partial grants:

  #{@join_partials.(@elixir, @join_fas)}

  Exception structs (granted as a family, derived by their
  `__exception__` marker; inert data, and rescuing `File.Error`
  does not grant `File`):

  #{@join_names.(@elixir_exceptions)}

  ## Granted: Erlang

  Gap-filling only: where an Elixir module covers the same ground,
  the Erlang module is not granted.

  #{@join_names.(for {mod, :all} <- @erlang, do: mod)}

  #{@join_partials.(@erlang, @join_fas)}

  ## Granted: web

  The route-authoring surface: curated grants for the modules agents
  write LiveViews and controllers against, never the whole Phoenix
  family, whose remaining modules stay denied by default without
  enumeration.

  #{@join_names.(for {mod, :all} <- @web, do: mod)}

  Partial grants:

  #{@join_partials.(@web, @join_fas)}

  ## Granted: data

  The data-authoring surface: the Ecto modules agents write schemas,
  changesets, queries and migrations against. `Ecto.Repo` is not
  among them; `Host.Repo` is the one repo agent code reaches.

  #{@join_names.(for {mod, :all} <- @data, do: mod)}

  Partial grants:

  #{@join_partials.(@data, @join_fas)}

  Ecto's exception structs, granted as a family like Elixir's:

  #{@join_names.(@data_exceptions)}

  ## Granted: host stdlib

  Each `Host.*` module joins here as it lands.

  #{@join_names.(Map.keys(@host))}

  Partial grants:

  #{@join_partials.(@host, @join_fas)}

  ## Granted: packages

  Expanded to per-module entries when the table is built, `@moduledoc
  false` modules excluded:

  #{@join_names.(@packages)}

  ## Denied with teaching signage

  #{@rendered_signage}

  ## Not granted

  Denied by absence with the generic error copy; the reason is
  recorded for the walk record only.

  #{@rendered_not_granted}
  """

  alias Beamlet.Policy

  @typedoc "A signage category; one shared teaching message each."
  @type category ::
          :fs
          | :concurrency
          | :confidentiality
          | :shell
          | :eval
          | :dynamic
          | :routing
          | :pubsub
          | :data
          | :migrations

  @doc """
  The default's grants: the curated table plus every shipped package
  expanded into per-module entries.

  Expansion runs when called, against whatever the beamlet has
  loaded, and excludes modules marked `@moduledoc false`: the policy
  gates only agent-written code, so granting a package's internals
  buys nothing but an invitation past its author's public line.
  Modules with no moduledoc at all stay granted, since an undocumented
  package must still expand.
  """
  @spec grants() :: Policy.grants()
  def grants do
    Enum.reduce(@packages, @granted, fn package, table -> Map.merge(table, expand!(package)) end)
  end

  @doc "The packages granted whole, by OTP application name."
  @spec packages() :: [atom()]
  def packages, do: @packages

  @doc "Every module with a deliberate-denial hint, grouped by category with its copy."
  @spec denials_by_category() :: [{category(), String.t(), [module()]}]
  def denials_by_category do
    grouped = Enum.group_by(@signage, fn {_mod, category} -> category end)

    for category <- @categories,
        entries = grouped[category] || [],
        entries != [] do
      modules = entries |> Enum.map(fn {mod, _} -> mod end) |> Enum.sort_by(&inspect/1)
      {category, @category_copy[category], modules}
    end
  end

  @doc "The modules carrying deliberate-denial signage."
  @spec signage_modules() :: [module()]
  def signage_modules, do: Map.keys(@signage)

  @doc "The `{module, function}` pairs carrying function-level signage."
  @spec signage_function_keys() :: [{module(), atom()}]
  def signage_function_keys, do: Map.keys(@signage_functions)

  @doc "The recorded non-grants: reason copy and the modules it covers."
  @spec not_granted() :: [{String.t(), [module()]}]
  def not_granted, do: @not_granted

  defp expand!(package) do
    Application.load(package)

    case Application.spec(package, :modules) do
      modules when is_list(modules) ->
        for module <- modules, not hidden?(module), into: %{}, do: {module, :all}

      nil ->
        raise ArgumentError,
              "the default policy grants #{inspect(package)}, but no such package is " <>
                "loaded on this beamlet"
    end
  end

  defp hidden?(module) do
    match?({:docs_v1, _, _, _, :hidden, _, _}, Code.fetch_docs(module))
  end
end
