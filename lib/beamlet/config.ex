defmodule Beamlet.Config do
  @moduledoc """
  How a beamlet runs: `:beamlet` application config, checked once at
  boot and read plainly after.

  One config surface, read at runtime, so a release or container
  sets it from the environment in `runtime.exs`, and a release can
  merge an operator's file from the data dir into it at boot
  (`Beamlet.Config.Provider`). `validate!/0` runs before a beamlet
  starts anything and fails the boot with a message naming the key at
  fault; the accessors then return what was checked, with defaults
  merged in, and never raise. A change is a restart.

      config :beamlet,
        data_dir: "/var/lib/beamlet",
        web: [endpoint: MyAppWeb.Endpoint],
        eval: [timeout: 60_000],
        define: [timeout: 60_000],
        mcp: [request_timeout: 90_000],
        http: [allow: ["homeassistant.local", "192.168.1.0/24"]]

  ## Keys

  Times are in milliseconds and sizes in bytes.

    * `data_dir`, required: the absolute path everything a beamlet
      keeps lives under.
    * `policies`, default `[]`: the policies declared beside
      `default`, a keyword list of name to document
      (`Beamlet.Policy`).
    * `eval`, the limits on the `eval` tool (`Beamlet.MCP.Eval` says
      what each protects):
        * `timeout`, default 30 seconds: how long one evaluation may
          run.
        * `max_heap_bytes`, default 128MB: how far one evaluation's
          heap may grow.
        * `max_output`, default 32KB: how much printed output one
          evaluation returns.
    * `define`, the limit on the `define` and `patch` tools
      (`Beamlet.MCP.Define`):
        * `timeout`, default 30 seconds: how long one compile may take.
    * `mcp`:
        * `request_timeout`, default 65 seconds: how long the
          transport waits for a request's answer before replying
          "Server unavailable". It must be longer than the eval and
          define timeouts, so a tool's own error, which says what
          happened, always arrives first.
    * `http` (`Host.HTTP`):
        * `allow`, default `[]`: the hosts agent HTTP reaches although
          they are on a private or reserved network, as host names, IP
          addresses and CIDR blocks.
    * `web` (`Beamlet.Router`):
        * `endpoint`, required to serve: the host's Phoenix endpoint,
          which serves the routes agents mount.
        * `prefix`, default `""`: the path the routes agents mount are
          served under, `""` for the root. Never under `/beamlet`,
          which is the beamlet's own.

  Adapter options for the two databases go under
  `config :beamlet, Beamlet.Repo` and `config :beamlet, Host.Repo`;
  their paths are derived from the data dir, never configured.

  ## The data dir

  Everything a beamlet persists lives under one directory, so a
  volume carries a beamlet whole:

    * `db/beamlet.db`, the system database (`Beamlet.Repo`): the
      owner, their sessions and the tokens.
    * `db/agent.db`, the agent database (`Host.Repo`): everything
      agents build in tables, the route table and key/value store
      included.
    * `code/`, the modules agents define: their sources, compiled
      beams and git history.
    * `files/`, the files agent code keeps through `Host.File`.
    * `config.exs`, the operator config file, when there is one
      (`Beamlet.Config.Provider`).

  The agent database, `code/` and `files/` are the unit agents build:
  `beamlet reset` deletes them together and keeps the rest
  (`Beamlet.CLI`).
  """

  @eval_defaults [timeout: 30_000, max_heap_bytes: 134_217_728, max_output: 32_768]
  @define_defaults [timeout: 30_000]
  @mcp_defaults [request_timeout: 65_000]
  @http_defaults [allow: []]
  @web_defaults [endpoint: nil, prefix: ""]
  @host_name_format ~r/\A[A-Za-z0-9_\-.]+\z/
  @prefix_format ~r{\A/[A-Za-z0-9_\-/]*[A-Za-z0-9_\-]\z}

  @doc """
  Checks every key, raising `ArgumentError` for the first at fault.

  `Beamlet` calls it before starting anything. The data dir must be
  set and absolute, since it holds state that must never silently
  depend on the working directory. The policies must be a keyword
  list of name to document, each document checked when the policies
  are built. The eval, define and mcp limits must be known keys with
  positive integers, and the MCP request timeout longer than both
  tool timeouts. The http group's `allow` must be a list of host
  names, IP addresses and CIDR blocks. The web group's endpoint must
  be a module, and its prefix empty or a path with a leading slash
  and no trailing one, outside `/beamlet`. Whether an endpoint is set
  is checked by the full boot, not here, since the system half runs
  without one.
  """
  @spec validate!() :: :ok
  def validate! do
    validate_data_dir!(Application.fetch_env(:beamlet, :data_dir))
    validate_policies!(Application.get_env(:beamlet, :policies, []))
    validate_limits!(:eval, @eval_defaults, Application.get_env(:beamlet, :eval, []))
    validate_limits!(:define, @define_defaults, Application.get_env(:beamlet, :define, []))
    validate_limits!(:mcp, @mcp_defaults, Application.get_env(:beamlet, :mcp, []))
    validate_request_timeout!()
    validate_http!(Application.get_env(:beamlet, :http, []))
    validate_web!(Application.get_env(:beamlet, :web, []))
    :ok
  end

  @doc "The data directory, an absolute path."
  @spec data_dir() :: Path.t()
  def data_dir, do: Application.fetch_env!(:beamlet, :data_dir)

  @doc "Directory holding Beamlet and agent database files."
  @spec db_dir() :: Path.t()
  def db_dir, do: Path.join(data_dir(), "db")

  @doc "The system database file (`Beamlet.Repo`): the owner, sessions and tokens."
  @spec system_db_file() :: Path.t()
  def system_db_file, do: Path.join(db_dir(), "beamlet.db")

  @doc "The agent database file (`Host.Repo`): everything agents build, the route table included."
  @spec agent_db_file() :: Path.t()
  def agent_db_file, do: Path.join(db_dir(), "agent.db")

  @doc "Directory holding the defined modules: their sources, beams and git history."
  @spec code_dir() :: Path.t()
  def code_dir, do: Path.join(data_dir(), "code")

  @doc "Directory holding the files agent code keeps through `Host.File`."
  @spec files_dir() :: Path.t()
  def files_dir, do: Path.join(data_dir(), "files")

  @doc """
  The policies declared beside `default`, as a keyword list of name
  to document (`Beamlet.Policy`). Empty when unset.
  """
  @spec policies() :: keyword()
  def policies, do: Application.get_env(:beamlet, :policies, [])

  @doc """
  The eval limits, merged over the defaults: `timeout` 30 seconds,
  `max_heap_bytes` 128MB, `max_output` 32KB (`Beamlet.MCP.Eval` says
  what each protects).
  """
  @spec eval() :: keyword()
  def eval, do: limits(:eval, @eval_defaults)

  @doc """
  The define limits, merged over the defaults: `timeout` 30 seconds,
  the time one compile may take (`Beamlet.MCP.Define`).
  """
  @spec define() :: keyword()
  def define, do: limits(:define, @define_defaults)

  @doc """
  The MCP limits, merged over the defaults: `request_timeout` 65
  seconds, how long the transport waits for a request's answer before
  replying "Server unavailable".
  """
  @spec mcp() :: keyword()
  def mcp, do: limits(:mcp, @mcp_defaults)

  @doc """
  The agent HTTP settings, merged over the defaults: `allow`, empty
  by default, the hosts `Host.HTTP` reaches although they are on a
  private or reserved network. A name entry matches a URL's host
  exactly, ignoring case; an IP address or CIDR block matches a host
  written as an address. A name that resolves into an allowed block
  is still refused.
  """
  @spec http() :: keyword()
  def http, do: limits(:http, @http_defaults)

  @doc """
  The web surface, merged over the defaults: `endpoint`, the host's
  Phoenix endpoint (nil when unset), and `prefix`, the path the
  routes agents mount are served under, `""` for the root.
  """
  @spec web() :: keyword()
  def web, do: limits(:web, @web_defaults)

  defp limits(key, defaults) do
    configured = Application.get_env(:beamlet, key, [])
    for {name, default} <- defaults, do: {name, Keyword.get(configured, name, default)}
  end

  defp validate_data_dir!({:ok, dir}) when is_binary(dir) do
    unless Path.type(dir) == :absolute do
      raise ArgumentError, "config :beamlet, :data_dir must be absolute, got: #{dir}"
    end
  end

  defp validate_data_dir!({:ok, other}) do
    raise ArgumentError,
          "config :beamlet, :data_dir must be a path string, got: #{inspect(other)}"
  end

  defp validate_data_dir!(:error) do
    raise ArgumentError, "config :beamlet, :data_dir is not set"
  end

  defp validate_policies!(policies) do
    unless Keyword.keyword?(policies) do
      raise ArgumentError,
            "config :beamlet, :policies must be a keyword list of policy name to " <>
              "document, got: #{inspect(policies)}"
    end
  end

  defp validate_limits!(key, defaults, limits) do
    unless Keyword.keyword?(limits) do
      raise ArgumentError,
            "config :beamlet, #{inspect(key)} must be a keyword list of limits, got: #{inspect(limits)}"
    end

    names = Keyword.keys(defaults)

    for {name, value} <- limits,
        name not in names or not is_integer(value) or value < 1 do
      raise ArgumentError,
            "config :beamlet, #{inspect(key)}: the limits are #{list(names)}, " <>
              "each a positive integer, got: #{inspect({name, value})}"
    end
  end

  # The transport's timeout answers "Server unavailable" and leaves
  # the request running, so a tool's own timeout, whose error says
  # what happened, must fire first.
  defp validate_request_timeout! do
    request_timeout = mcp()[:request_timeout]
    eval_timeout = eval()[:timeout]
    define_timeout = define()[:timeout]

    unless request_timeout > max(eval_timeout, define_timeout) do
      raise ArgumentError,
            "config :beamlet, :mcp: request_timeout (#{request_timeout}) must be greater " <>
              "than the eval timeout (#{eval_timeout}) and the define timeout " <>
              "(#{define_timeout}), or a tool that runs to its own timeout is answered " <>
              "\"Server unavailable\" instead of its error"
    end
  end

  defp validate_http!(http) do
    unless Keyword.keyword?(http) and Keyword.keys(http) -- Keyword.keys(@http_defaults) == [] do
      raise ArgumentError, "config :beamlet, :http takes allow, got: #{inspect(http)}"
    end

    allow = Keyword.get(http, :allow, [])

    unless is_list(allow) do
      raise ArgumentError,
            "config :beamlet, :http: allow must be a list of host names, IP addresses " <>
              "and CIDR blocks, got: #{inspect(allow)}"
    end

    for entry <- allow, not allow_entry?(entry) do
      raise ArgumentError,
            "config :beamlet, :http: allow takes host names such as \"homeassistant.local\", " <>
              "IP addresses and CIDR blocks such as \"192.168.1.0/24\", got: #{inspect(entry)}"
    end
  end

  defp allow_entry?(entry) when is_binary(entry) do
    match?({:ok, _}, :inet.parse_address(String.to_charlist(entry))) or
      match?({:ok, _}, InetCidr.parse_cidr(entry)) or
      Regex.match?(@host_name_format, entry)
  end

  defp allow_entry?(_entry), do: false

  defp validate_web!(web) do
    unless Keyword.keyword?(web) and Keyword.keys(web) -- Keyword.keys(@web_defaults) == [] do
      raise ArgumentError,
            "config :beamlet, :web takes endpoint and prefix, got: #{inspect(web)}"
    end

    case Keyword.get(web, :endpoint) do
      endpoint when is_atom(endpoint) and not is_boolean(endpoint) ->
        :ok

      other ->
        raise ArgumentError,
              "config :beamlet, :web: endpoint must be a module, got: #{inspect(other)}"
    end

    prefix = Keyword.get(web, :prefix, "")

    unless prefix == "" or (is_binary(prefix) and Regex.match?(@prefix_format, prefix)) do
      raise ArgumentError,
            "config :beamlet, :web: prefix must be \"\" or a path such as \"/app\", " <>
              "with no trailing slash, got: #{inspect(prefix)}"
    end

    if prefix == "/beamlet" or String.starts_with?(prefix, "/beamlet/") do
      raise ArgumentError,
            "config :beamlet, :web: prefix cannot be under /beamlet, which is reserved for " <>
              "the beamlet's own pages, got: #{inspect(prefix)}"
    end
  end

  defp list([name]), do: to_string(name)

  defp list(names) do
    {last, rest} = List.pop_at(names, -1)
    Enum.join(rest, ", ") <> " and " <> to_string(last)
  end
end
