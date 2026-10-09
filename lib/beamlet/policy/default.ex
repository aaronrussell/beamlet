defmodule Beamlet.Policy.Default do
  # The curation record: every name-based ruling of the policy Beamlet
  # ships lives in this module's data, and nowhere else. Pure data and
  # accessors; composition and enforcement live in Beamlet.Policy, and
  # the teaching copy for a refusal in Beamlet.Policy.Signage. The
  # coverage test in default_test.exs proves every documented platform
  # module is either granted or recorded as not granted, and the golden
  # fixture pins the composed table. The moduledoc below embeds the
  # policy as an agent reads it, rendered from the data at compile
  # time.

  # ── Grants ────────────────────────────────────────────────────────

  # Partial grants carry their slice rationale: Function.capture
  # builds funs from names (dynamic dispatch); List and String lose
  # their atom constructors, which turn data into module names; IO is
  # granted for output only (device-directed IO reaches arbitrary
  # processes); Macro keeps its string helpers, which name tables and
  # files from module names, and loses everything that builds or
  # expands code; Path is pure string manipulation, safe because
  # Host.File re-checks every path it receives, except wildcard, which
  # touches the real filesystem; System keeps its clock/VM
  # introspection and loses shell, env, and lifecycle control.
  # Exception loses the forms that take a stacktrace, which reach
  # ErlangError.normalize/2: it applies the module and function named
  # in a stacktrace entry's error_info, and a stacktrace is a list the
  # agent can build. blame_mfa reads any module's clauses from its
  # beam, and FunctionClauseError.blame/2 reaches it from a hand-built
  # struct. Calendar loses put_time_zone_database, a VM-wide write that
  # runs the agent's module in every DateTime call on the default
  # database, Beamlet's included.
  @elixir %{
    Access => :all,
    Atom => :all,
    Base => :all,
    Bitwise => :all,
    Calendar => {:except, [put_time_zone_database: 1]},
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
    ErlangError => {:except, [normalize: 2]},
    Exception =>
      {:except,
       [
         blame: 3,
         blame_mfa: 3,
         format: 3,
         format_banner: 3,
         format_exit: 1,
         normalize: 3
       ]},
    Float => :all,
    Function => {:except, [capture: 3]},
    FunctionClauseError => {:except, [blame: 2]},
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
    List => {:except, [to_atom: 1, to_existing_atom: 1]},
    List.Chars => :all,
    Macro => {:only, [underscore: 1, camelize: 1, to_string: 1]},
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
  # modules: rescuing File.Error does not grant File. The families
  # merge before the hand-written rows, so a carve-out on an exception
  # module wins over its family's :all.
  @elixir_exceptions for mod <- Application.spec(:elixir, :modules),
                         Code.ensure_loaded?(mod),
                         function_exported?(mod, :__struct__, 0),
                         match?(%{__exception__: true}, mod.__struct__()),
                         do: mod

  # Erlang is gap-filling only: where Elixir covers the ground, the
  # Erlang module is not granted (recorded under not-granted below).
  # :erlang keeps term hashing and checksums; term_to_binary and
  # binary_to_term are denied both ways (binary_to_term constructs
  # atoms and funs, the String.to_atom posture). :crypto loses its
  # engine family, which loads a native shared object from a path;
  # the engine key maps the rest accept need a handle only those
  # functions make.
  @erlang %{
    :binary => :all,
    :crypto =>
      {:except,
       [
         engine_add: 1,
         engine_by_id: 1,
         engine_ctrl_cmd_string: 3,
         engine_ctrl_cmd_string: 4,
         engine_get_all_methods: 0,
         engine_get_id: 1,
         engine_get_name: 1,
         engine_list: 0,
         engine_load: 3,
         engine_load: 4,
         engine_methods_convert_to_bitmask: 2,
         engine_register: 2,
         engine_remove: 1,
         engine_unload: 1,
         engine_unload: 2,
         engine_unregister: 2,
         ensure_engine_loaded: 2,
         ensure_engine_loaded: 3,
         ensure_engine_unloaded: 1,
         ensure_engine_unloaded: 2
       ]},
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
  # flavor and send_file serve arbitrary paths. Phoenix.Token is
  # absent because it signs with the endpoint secret.
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
  # repo agent code reaches, and the adapters, the sandbox and Exqlite
  # beneath it open database files by path. Ecto.Multi loses run/5 and
  # merge/4, which apply a module and function the agent names; run/3
  # and merge/2 take a fun instead. Ecto.Schema loses its @doc false
  # plumbing, which the macros expand to after the scan:
  # __embeds_module__ compiles the block it is handed, and the rest
  # call callbacks on whatever module they are given. Ecto.Type loses
  # its adapter_* plumbing for the same reason.
  @data %{
    Ecto => :all,
    Ecto.Changeset => :all,
    Ecto.Enum => :all,
    Ecto.Migration => {:except, [execute_file: 1, execute_file: 2]},
    Ecto.Multi => {:except, [merge: 4, run: 5]},
    Ecto.ParameterizedType => :all,
    Ecto.Query => :all,
    Ecto.Query.API => :all,
    Ecto.Schema =>
      {:except,
       [
         __after_verify__: 1,
         __belongs_to__: 4,
         __define_timestamps__: 2,
         __embeds_many__: 4,
         __embeds_module__: 4,
         __embeds_one__: 4,
         __field__: 4,
         __has_many__: 4,
         __has_one__: 4,
         __many_to_many__: 4,
         __schema__: 1,
         __schema__: 5,
         __timestamps__: 1,
         association: 5
       ]},
    Ecto.Type => {:except, [adapter_autogenerate: 2, adapter_dump: 3, adapter_load: 3]},
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

  # What Host.HTTP returns and raises. Req itself is not granted:
  # Host.HTTP is where the outbound guard and the refusal of options
  # that bypass it (plug, unix_socket, connect_options, the disk
  # cache, netrc) live, and a request made through Req directly would
  # pass neither. The response struct and the exceptions are inert
  # data.
  @http %{Req.Response => :all}

  @http_exceptions for mod <- Application.spec(:req, :modules) || [],
                       Code.ensure_loaded?(mod),
                       function_exported?(mod, :__struct__, 0),
                       match?(%{__exception__: true}, mod.__struct__()),
                       do: mod

  # The host stdlib, one row per module. Every module but Host.Repo
  # is granted whole: each function is meant for agent code, and
  # remove stays in step with the tools by the operator's choice
  # (Beamlet.Policy). Host.Repo: denied are the repo's process
  # controls (put_dynamic_repo redirects every call to any running
  # repo by name, the system repo included; start_link, stop and
  # disconnect_all touch the pool). Raw SQL is granted: the agent
  # database is the agent's to break, and the statements that reach
  # past it, ATTACH DATABASE and VACUUM INTO, are refused by the SQLite
  # authorizer on every connection (Host.Repo.init/2).
  @host %{
    Host.Code => :all,
    Host.File => :all,
    Host.HTTP => :all,
    Host.HTTP.BlockedError => :all,
    Host.KV => :all,
    Host.Migrator => :all,
    Host.PubSub => :all,
    Host.Router => :all,
    Host.Web => :all,
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
  @package_names [:jason]

  # The language's self-reference: __MODULE__ is always the module
  # being defined, granted by construction. Keyed by the sentinel the
  # scanner resolves it to; not a platform module, so outside the
  # coverage walk.
  @language %{:__MODULE__ => :all}

  @granted Map.new(@elixir_exceptions ++ @data_exceptions ++ @http_exceptions, &{&1, :all})
           |> Map.merge(@elixir)
           |> Map.merge(@erlang)
           |> Map.merge(@web)
           |> Map.merge(@data)
           |> Map.merge(@http)
           |> Map.merge(@host)
           |> Map.merge(@language)

  # ── Not granted ───────────────────────────────────────────────────
  #
  # The rest of the walk: denied by absence, the reason recorded here
  # so the coverage test can prove the walk exhaustive and future
  # revisits can read why. Whether a refusal carries teaching copy is
  # Beamlet.Policy.Signage's business, not this record's.

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
    {"reads or writes the real filesystem; Host.File is the scoped door",
     [
       File,
       File.Stat,
       File.Stream,
       :beam_lib,
       :disk_log,
       :erl_tar,
       :file,
       :file_sorter,
       :filelib,
       :wrap_log_reader,
       :zip
     ]},
    {"process machinery, distribution, and node management, until supervised processes arrive",
     [
       DynamicSupervisor,
       GenServer,
       Node,
       PartitionSupervisor,
       Process,
       Registry,
       StringIO,
       Supervisor,
       Task,
       Task.Supervisor,
       :auth,
       :data_publisher,
       :erl_epmd,
       :erpc,
       :gen_event,
       :gen_server,
       :gen_statem,
       :global,
       :global_group,
       :heart,
       :net_adm,
       :net_kernel,
       :peer,
       :pg,
       :pool,
       :proc_lib,
       :rpc,
       :seq_trace,
       :slave,
       :supervisor,
       :supervisor_bridge,
       :sys,
       :timer,
       :trace
     ]},
    {"process-owned state; Host.KV is the durable home",
     [Agent, :atomics, :counters, :dets, :digraph, :digraph_utils, :ets, :persistent_term]},
    {"environment and application config may hold credentials",
     [Application, Config, Config.Provider, Config.Reader, :application]},
    {"shell and OS access", [Port, :os]},
    {"raw network access; Host.HTTP carries the HTTP story",
     [:gen_sctp, :gen_tcp, :gen_udp, :inet, :inet_res, :net, :socket]},
    {"parsing, evaluation, and compilation of code",
     [
       Code,
       Code.Fragment,
       Module,
       :c,
       :code,
       :epp,
       :erl_eval,
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
    {"deprecated modules",
     [Behaviour, Dict, GenEvent, HashDict, HashSet, Set, Supervisor.Spec, :gen_fsm]},
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

  # Rendered from the curated table rather than grants/0, which this
  # module cannot call while it compiles. The packages add only whole
  # grants, which the rendering never lists, so the text is the same.
  @moduledoc """
  The policy Beamlet ships, which every token starts from.

  `default` grants everyday Elixir, a few Erlang modules, the Phoenix
  and Ecto modules agents build pages and data with, and the `Host.*`
  stdlib. It leaves out what reaches past the beamlet directly: the
  filesystem, processes, the environment and loading code. Agent code
  does those through `Host.*` instead. To change any of it, declare a
  policy (`Beamlet.Policy`).

  ## The policy

  This is `default` as an agent reads it with
  `Host.Code.print_policy/0`, and as
  `beamlet policies.show default` prints it.

  ```text
  #{Beamlet.Policy.render(%Beamlet.Policy{name: "default", grants: @granted})}
  ```
  """

  alias Beamlet.Policy

  @doc """
  The default's grant table, with each package expanded into its
  modules.

  A package's modules marked `@moduledoc false` are left out.
  """
  @spec grants() :: Policy.grants()
  def grants do
    Enum.reduce(@package_names, @granted, fn package, table ->
      Map.merge(table, expand!(package))
    end)
  end

  @doc "The packages granted whole, by OTP application name."
  @spec packages() :: [atom()]
  def packages, do: @package_names

  @doc """
  The Phoenix and Ecto modules granted one by one, as listed under
  web and data.
  """
  @spec framework_modules() :: [module()]
  def framework_modules, do: Map.keys(@web) ++ Map.keys(@data)

  @doc """
  The modules left out on purpose, grouped by reason.

  Nothing at runtime reads it. A module is denied by being absent
  from the grants.
  """
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
