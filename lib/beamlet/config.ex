defmodule Beamlet.Config do
  @moduledoc """
  The `:beamlet` application config.

      config :beamlet,
        data_dir: "/var/lib/beamlet",
        web: [endpoint: MyAppWeb.Endpoint],
        eval: [timeout: 60_000],
        mcp: [request_timeout: 90_000],
        http: [allow: ["homeassistant.local", "192.168.1.0/24"]]

  The beamlet checks every key when it starts. A bad value stops the
  boot with a message naming the key. A change takes a restart.

  Times are in milliseconds and sizes in bytes.

  ## Keys

  * `:data_dir` - The directory where the beamlet keeps everything:
    its databases, the code agents define and the files they keep.
    Required. It must be an absolute path to a directory that already
    exists.
  * `:policies` - The policies a token can have besides `default`, as
    a keyword list of name to policy. None by default.
    `Beamlet.Policy` describes how to write one.
  * `:eval` - Limits on the `eval` tool. `timeout` is how long one
    evaluation may run (30 seconds). `max_heap_bytes` caps the memory
    it may use (128 MB), and `max_output` the output returned to the
    model (32 KB). `Beamlet.MCP.Eval` says what happens when each is
    reached.
  * `:define` - `timeout` is how long one `define` or `patch` may take
    to compile (30 seconds).
  * `:mcp` - `request_timeout` is how long the MCP server waits for a
    tool to answer before replying "Server unavailable" (65 seconds).
    It must be longer than the eval and define timeouts, so a slow
    tool reports its own error first.
  * `:http` - `allow` lists the hosts on private networks that agent
    code may reach through `Host.HTTP`, as names, IP addresses or CIDR
    blocks. A name must be listed as a name: allowing its address
    or block is not enough. Empty by default, so agent code reaches
    only the public internet.
  * `:web` - `endpoint` names the Phoenix endpoint that forwards to
    `Beamlet.Router`. Required. `prefix` is a path to serve the routes
    agents mount under, such as `"/app"`, and cannot be under
    `/beamlet`. Empty by default, which serves them at the root.
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

  `Beamlet` calls it before starting anything. It does not check that
  an endpoint is set. A full boot checks that afterwards.
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

  @doc "The directory holding both database files."
  @spec db_dir() :: Path.t()
  def db_dir, do: Path.join(data_dir(), "db")

  @doc "The beamlet's own database file, used by `Beamlet.Repo`."
  @spec beamlet_db_file() :: Path.t()
  def beamlet_db_file, do: Path.join(db_dir(), "beamlet.db")

  @doc "The agent database file, used by `Host.Repo`."
  @spec agent_db_file() :: Path.t()
  def agent_db_file, do: Path.join(db_dir(), "agent.db")

  @doc "The directory holding the modules agents define, with their git history."
  @spec code_dir() :: Path.t()
  def code_dir, do: Path.join(data_dir(), "code")

  @doc "The directory holding the files agent code keeps through `Host.File`."
  @spec files_dir() :: Path.t()
  def files_dir, do: Path.join(data_dir(), "files")

  @doc "The policies declared besides `default`."
  @spec policies() :: keyword()
  def policies, do: Application.get_env(:beamlet, :policies, [])

  @doc "The `:eval` settings, with the defaults filled in."
  @spec eval() :: keyword()
  def eval, do: settings(:eval, @eval_defaults)

  @doc "The `:define` settings, with the defaults filled in."
  @spec define() :: keyword()
  def define, do: settings(:define, @define_defaults)

  @doc "The `:mcp` settings, with the defaults filled in."
  @spec mcp() :: keyword()
  def mcp, do: settings(:mcp, @mcp_defaults)

  @doc "The `:http` settings, with the defaults filled in."
  @spec http() :: keyword()
  def http, do: settings(:http, @http_defaults)

  @doc "The `:web` settings, with the defaults filled in."
  @spec web() :: keyword()
  def web, do: settings(:web, @web_defaults)

  defp settings(key, defaults) do
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
