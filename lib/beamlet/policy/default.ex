defmodule Beamlet.Policy.Default do
  # The curation record: every name-based ruling of the policy Beamlet
  # ships lives in this module's data, and nowhere else. Pure data and
  # accessors; composition and enforcement live in Beamlet.Policy, and
  # the teaching copy for a refusal in Beamlet.Policy.Signage. The
  # coverage test in default_test.exs proves every documented platform
  # module is either granted or recorded as not granted, and the golden
  # fixture pins the composed table. The moduledoc below is rendered
  # from the data at compile time, so the printed record cannot drift
  # from it.

  # ── Grants ────────────────────────────────────────────────────────

  # Partial grants carry their slice rationale: Function.capture
  # builds funs from names (dynamic dispatch); IO is granted for
  # output only (device-directed IO reaches arbitrary processes);
  # Macro keeps its string helpers, which name tables and files from
  # module names, and loses everything that builds or expands code;
  # Path is pure string manipulation, safe because Host.File re-checks
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
  # beneath it open database files by path.
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

  # The host stdlib, one row per module as each lands. Host.Code,
  # Host.File, Host.KV, Host.Migrator and Host.PubSub are granted
  # whole: every function is meant for agent code, and remove stays
  # in step with the tools by the operator's choice (Beamlet.Policy).
  # Host.Repo: denied are the repo's process
  # controls (put_dynamic_repo redirects every call to any running
  # repo by name, the system repo included; start_link, stop and
  # disconnect_all touch the pool). Raw SQL is granted: the agent
  # database is the agent's to break, and the one statement that
  # reached past it, ATTACH DATABASE, is refused by the SQLite
  # authorizer on every connection (Beamlet.SQLiteAuthorizer).
  @host %{
    Host.Code => :all,
    Host.File => :all,
    Host.KV => :all,
    Host.Migrator => :all,
    Host.PubSub => :all,
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
  # turning them away teaches nothing. A description is for the
  # discovery listing where the package's own says nothing: Req's
  # .app description is its bare name and its moduledoc opens "The
  # high-level API."
  @packages [
    :jason,
    {:req, description: "Req is a batteries-included HTTP client for Elixir."}
  ]

  @package_descriptions Map.new(@packages, fn
                          {app, opts} -> {app, opts[:description]}
                          app -> {app, nil}
                        end)

  @package_names Map.keys(@package_descriptions)

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
    {"raw network access; Req carries the HTTP story",
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
  platform module is either granted here or recorded as not granted,
  and the golden fixture pins the composed table. Everything below
  this paragraph is rendered from the data at compile time and cannot
  drift from it.

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

  #{@join_names.(@package_names)}

  ## Not granted

  Denied by absence; the reason is recorded for the walk record only.
  The few refusals that carry teaching copy are listed in
  `Beamlet.Policy.Signage`.

  #{@rendered_not_granted}
  """

  alias Beamlet.Policy

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
    Enum.reduce(@package_names, @granted, fn package, table ->
      Map.merge(table, expand!(package))
    end)
  end

  @doc "The packages granted whole, by OTP application name."
  @spec packages() :: [atom()]
  def packages, do: @package_names

  @doc "The curated description of a shipped package for the discovery listing, or nil to use the package's own."
  @spec package_description(atom()) :: String.t() | nil
  def package_description(app), do: Map.get(@package_descriptions, app)

  @doc """
  The framework modules: the curated web and data authoring surface,
  granted module by module because the rest of their applications is
  machinery. Discovery lists them apart from the packages granted
  whole.
  """
  @spec framework_modules() :: [module()]
  def framework_modules, do: Map.keys(@web) ++ Map.keys(@data)

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
