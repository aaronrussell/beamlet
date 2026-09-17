defmodule Host.Router do
  @moduledoc """
  Mount your modules on your beamlet's web surface: URLs served live
  by your beamlet, answered by modules you defined with `define`.

  `live/2` mounts a LiveView page; `get/3`, `post/3`, `put/3`,
  `patch/3` and `delete/3` mount a controller action for that verb.
  Routes persist across restarts, and every route is public: anyone
  who can reach your beamlet can request it.

  Two words to keep apart. A *path* is what you choose and what
  every function here takes: `"/todos"`, never carrying a prefix the
  operator may have configured. A *URL* is what you give people or
  external services; `url/1` builds it. In a template, `~p"/todos"`
  (imported by `use Host.Web`) turns a path into the browser path a
  link needs. A path whose first segment starts with `_` or `~` is
  your beamlet's own (`/_mcp`, `/_live`, `/_assets`) and cannot be
  mounted.

  Mounting prints the route and its URL and returns `:ok`;
  `unmount/1` prints what it removed. `print_routes/0` prints the
  route table. `call/4` calls a mounted path in this process and
  returns the response as data:

      call(:get, "/todos")
      #=> %{status: 200, headers: %{"content-type" => "text/html; charset=utf-8", ...},
      #     body: "<!DOCTYPE html>..."}

  Mounting and unmounting act as you, the token behind the `eval`,
  and a route records who mounted it. A served route acts as nobody:
  inside one, these verbs and `Host.Code` raise, whether the request
  came from a browser or through `call/4`, which sets your principal
  aside for the duration of the request so the two behave the same.
  """

  alias Beamlet.Config
  alias Beamlet.Principal
  alias Beamlet.Route
  alias Beamlet.Routes

  @verbs [:get, :post, :put, :patch, :delete]

  @doc """
  Mounts a LiveView page at `path`, e.g.
  `live("/todos", Todo.PageLive)`. Prints the route and the URL it
  is served at.

  The module must be a LiveView (`use Host.Web, :live_view`). An
  optional live action arrives as `socket.assigns.live_action`, not
  in the mount params, so one LiveView can serve several paths:
  `live("/todos/new", Todo.PageLive, :new)`.
  """
  @spec live(String.t(), module(), atom() | nil) :: :ok
  def live(path, module, action \\ nil) do
    principal = principal!(:live)
    validate_path!(path)
    ensure_defined!(module)
    ensure_live!(module)
    validate_live_action!(action)

    mount!(%{
      kind: :live_view,
      path: path,
      module: inspect(module),
      action: action && Atom.to_string(action),
      principal: principal
    })
  end

  @doc """
  Mounts a controller action for GET requests at `path`, e.g.
  `get("/report", Report.Api, :show)`, called as
  `show(conn, params)`. Prints the route and the URL it is served at.

  Controller routes answer JSON/webhook-style requests: no session,
  no CSRF, so external services can call them directly. The module
  must be a Phoenix controller (`use Host.Web, :controller`).
  """
  @spec get(String.t(), module(), atom()) :: :ok
  def get(path, module, action), do: mount_action(:get, path, module, action)

  @doc """
  Mounts a controller action for POST requests at `path`, e.g.
  `post("/hooks/github", Hooks.Github, :create)`. Prints the route
  and its URL, the one external services should call.
  """
  @spec post(String.t(), module(), atom()) :: :ok
  def post(path, module, action), do: mount_action(:post, path, module, action)

  @doc """
  Mounts a controller action for PUT requests at `path`. Prints the
  route and the URL it is served at.
  """
  @spec put(String.t(), module(), atom()) :: :ok
  def put(path, module, action), do: mount_action(:put, path, module, action)

  @doc """
  Mounts a controller action for PATCH requests at `path`. Prints
  the route and the URL it is served at.
  """
  @spec patch(String.t(), module(), atom()) :: :ok
  def patch(path, module, action), do: mount_action(:patch, path, module, action)

  @doc """
  Mounts a controller action for DELETE requests at `path`. Prints
  the route and the URL it is served at.
  """
  @spec delete(String.t(), module(), atom()) :: :ok
  def delete(path, module, action), do: mount_action(:delete, path, module, action)

  @doc """
  Unmounts every route at `path`, e.g. `unmount("/todos")`: the
  page or action stops being served. Pass `verb: :post` to remove
  only that verb's route and leave the others mounted. Prints each
  route removed.
  """
  @spec unmount(String.t(), keyword()) :: :ok
  def unmount(path, opts \\ []) do
    _principal = principal!(:unmount)
    validate_path!(path)
    verb = unmount_verb!(opts)
    filters = if verb, do: [path: path, verb: verb], else: [path: path]

    case Routes.list(filters) do
      [] ->
        raise nothing_mounted(path, verb)

      routes ->
        Enum.each(routes, &Routes.delete/1)

        case Routes.regenerate() do
          :ok ->
            Enum.each(routes, fn route -> IO.puts("Unmounted #{summary(route)}") end)

          {:error, message} ->
            raise "unmounted, but the router failed to regenerate: #{message}"
        end
    end
  end

  @doc """
  The browser path for `path`: `path("/todos")` is `"/todos"` on a
  beamlet serving at the root, and `"/app/todos"` on one whose
  operator fenced agent routes under `/app`. In a template,
  `~p"/todos"` is the same thing; use this form in code.
  """
  @spec path(String.t()) :: String.t()
  def path(path) do
    validate_path!(path)
    browser_path(path)
  end

  @doc """
  The full URL for `path`, e.g. `url("/todos")` is
  `"http://localhost:4000/todos"`. This is what you show people and
  register with external services.
  """
  @spec url(String.t()) :: String.t()
  def url(path), do: base_url() <> path(path)

  @doc ~S"""
  The `~p` sigil: the browser path for a route path, for links and
  forms in templates, `<.link navigate={~p"/todos/#{id}"}>`. It is
  `path/1` in sigil form: it prepends the operator's prefix, if any,
  and nothing else, so there is no compile-time route check. Comes
  imported with `use Host.Web`.
  """
  defmacro sigil_p({:<<>>, _meta, [first | _]}, [])
           when is_binary(first) and first != "" and binary_part(first, 0, 1) != "/" do
    first = String.trim(first)
    preview = if String.length(first) > 40, do: String.slice(first, 0, 40) <> "...", else: first

    raise ArgumentError,
          "~p takes a route path starting with /, e.g. ~p\"/todos\" — got " <>
            "~p#{inspect(preview)}. A template is written with ~H, not ~p."
  end

  defmacro sigil_p({:<<>>, _meta, _parts} = path, []) do
    quote do
      Host.Router.path(unquote(path))
    end
  end

  defmacro sigil_p(_path, modifiers) do
    raise ArgumentError,
          "~p takes no modifiers — got ~p...#{modifiers}. Write ~p\"/todos\""
  end

  @doc """
  Calls a mounted route in this process and returns its response,
  e.g. `call(:get, "/todos")` or
  `call(:post, "/hooks/github", %{"action" => "opened"})`.

  `path` is the path you mounted. `data` is a map or a string: on
  GET a map becomes the query string; on other verbs a map is sent
  as a JSON body and a string as the raw body. Pass
  `headers: [{"x-hub-signature", sig}]` to add request headers.

  Returns `%{status: 201, headers: %{"content-type" => ...}, body: ...}`.
  A JSON response body is decoded; any other body is the raw string.
  A LiveView page answers GET with its rendered HTML. Anything the
  route prints appears in your output. If the route crashes, the
  crash is raised here with the route's stacktrace. The call is a
  real request: records and files the route creates persist, and
  the route acts as nobody, exactly as it does from a browser.
  """
  @spec call(Route.verb(), String.t(), map() | String.t() | nil, keyword()) :: %{
          status: pos_integer(),
          headers: %{String.t() => String.t()},
          body: term()
        }
  def call(verb, path, data \\ nil, opts \\ []) do
    validate_verb!(verb)
    validate_path!(path)
    headers = call_headers!(opts)
    {body, headers} = call_body!(verb, data, headers)

    conn =
      Enum.reduce(headers, Plug.Test.conn(verb, browser_path(path), body), fn {name, value},
                                                                              conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)

    conn = as_nobody(fn -> dispatch!(conn, verb, path) end)
    drain(conn)
    %{status: conn.status, headers: Map.new(conn.resp_headers), body: decode_body(conn)}
  end

  @doc """
  Prints the mounted routes: verb, path, the module (and action)
  serving each, and the user who mounted it, under the base URL they
  are served from. A route whose module is gone or no longer fits it
  is marked as not served.
  """
  @spec print_routes() :: :ok
  def print_routes do
    IO.puts(render_routes())
    :ok
  end

  # ── Mounting ──────────────────────────────────────────────────────

  defp mount_action(verb, path, module, action) do
    principal = principal!(verb)
    validate_path!(path)
    validate_action!(action)
    ensure_defined!(module)
    ensure_controller!(module, action)

    mount!(%{
      kind: :controller,
      verb: verb,
      path: path,
      module: inspect(module),
      action: Atom.to_string(action),
      principal: principal
    })
  end

  defp mount!(attrs) do
    case Routes.create(attrs) do
      {:ok, route} -> regenerate!(route)
      {:error, changeset} -> raise mount_error(changeset, attrs)
    end
  end

  defp regenerate!(route) do
    case Routes.regenerate() do
      :ok ->
        IO.puts("Mounted #{summary(route)}\nURL: #{base_url() <> browser_path(route.path)}")

      {:error, message} ->
        Routes.delete(route)
        raise "could not mount #{route.path} — the router failed to regenerate: #{message}"
    end
  end

  defp mount_error(%Ecto.Changeset{errors: errors}, attrs) do
    cond do
      Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end) ->
        conflict_error(attrs)

      Keyword.has_key?(errors, :path) ->
        "the path must start with / and contain only letters, digits, " <>
          "_ - . : * and / — got: #{inspect(attrs.path)}"

      true ->
        {field, {message, _opts}} = List.last(errors)
        "#{field} #{message}"
    end
  end

  defp conflict_error(attrs) do
    verb = Map.get(attrs, :verb, :get)

    taken =
      case Routes.list(path: attrs.path, verb: verb) do
        [route | _rest] -> "#{target_label(route)}, mounted by #{mounted_by(route)}"
        [] -> "another route"
      end

    "#{verb_word(verb)} #{attrs.path} is already mounted — #{taken}. " <>
      "Unmount it first, or choose another path."
  end

  defp nothing_mounted(path, nil) do
    "nothing is mounted at #{path} — Host.Router.print_routes() shows the mounted routes"
  end

  defp nothing_mounted(path, verb) do
    "no #{verb_word(verb)} route is mounted at #{path} — " <>
      "Host.Router.print_routes() shows the mounted routes"
  end

  # ── Calling ───────────────────────────────────────────────────────

  # The principal is set aside, not just hidden: a route under call/4
  # must raise where it would raise in a browser, so what an agent
  # tests here is what a visitor gets.
  defp as_nobody(fun) do
    principal = Principal.current()
    Principal.delete_current()

    try do
      fun.()
    after
      if principal, do: Principal.put_current(principal)
    end
  end

  defp dispatch!(conn, verb, path) do
    endpoint = endpoint()
    endpoint.call(conn, endpoint.init([]))
  catch
    kind, reason ->
      stack = __STACKTRACE__
      drain(conn)

      reraise "#{verb_word(verb)} #{path} crashed: " <>
                Exception.format_banner(kind, reason, stack),
              trim_stack(stack)
  end

  # The frames above the endpoint are the route's own story; below it
  # is plumbing and the caller's eval, which eval's output would only
  # repeat.
  defp trim_stack(stack) do
    endpoint = endpoint()

    case Enum.find_index(stack, &match?({^endpoint, _fun, _arity, _loc}, &1)) do
      nil -> stack
      index -> Enum.take(stack, index)
    end
  end

  # The test adapter reports a sent response to the owner process as
  # mailbox messages; left behind, they would reach a LiveView's
  # handle_info when a page calls a route.
  defp drain(%Plug.Conn{adapter: {_adapter, %{ref: ref}}}) do
    already_sent = Plug.Conn.Adapter.already_sent()

    receive do
      ^already_sent -> :ok
    after
      0 -> :ok
    end

    receive do
      {^ref, _response} -> :ok
    after
      0 -> :ok
    end
  end

  defp decode_body(conn) do
    with [type | _rest] <- Plug.Conn.get_resp_header(conn, "content-type"),
         {:ok, "application", subtype, _params} <- Plug.Conn.Utils.media_type(type),
         true <- subtype == "json" or String.ends_with?(subtype, "+json"),
         {:ok, decoded} <- JSON.decode(conn.resp_body) do
      decoded
    else
      _other -> conn.resp_body
    end
  end

  # ── Printing ──────────────────────────────────────────────────────

  defp render_routes do
    case Routes.list() do
      [] ->
        "No routes are mounted. Mount an HTML page with Host.Router.live(path, module), " <>
          "or an API/webhook action with Host.Router.get(path, module, action) " <>
          "and its sibling verb functions."

      routes ->
        Enum.join([served_line() | Enum.map(routes, &route_line/1)], "\n")
    end
  end

  defp served_line do
    case prefix() do
      "" -> "Paths are served at #{base_url()}:"
      prefix -> "Paths are served under #{base_url() <> prefix}:"
    end
  end

  defp route_line(route) do
    verb = route.verb |> verb_word() |> String.pad_trailing(7)
    line = "#{verb}#{route.path} — #{target_label(route)} (#{mounted_by(route)})"

    if Routes.servable?(route) do
      line
    else
      line <> " — not served: the target is missing or no longer fits the route"
    end
  end

  defp summary(route), do: "#{verb_word(route.verb)} #{route.path} — #{target_label(route)}"

  defp target_label(%Route{action: nil} = route), do: route.module

  defp target_label(%Route{kind: :controller} = route),
    do: "#{route.module}, action: :#{route.action}"

  defp target_label(%Route{kind: :live_view} = route),
    do: "#{route.module}, live_action: :#{route.action}"

  defp mounted_by(route) do
    case Route.principal(route) do
      {:ok, principal} -> principal.user_name
      :error -> "an unknown user"
    end
  end

  defp verb_word(verb), do: verb |> Atom.to_string() |> String.upcase()

  # ── Validation ────────────────────────────────────────────────────

  defp principal!(fun) do
    Principal.current() ||
      raise "Host.Router.#{fun} works from eval, where your code acts as you; " <>
              "there is no principal in this process"
  end

  defp validate_path!("/" <> _rest = path) do
    reject_reserved!(path)
    reject_prefixed!(path)
  end

  defp validate_path!(path) do
    raise "the path must be a string starting with /, e.g. \"/todos\" — got: #{inspect(path)}"
  end

  defp reject_reserved!(path) do
    case first_segment(path) do
      <<mark, _rest::binary>> = segment when mark in [?_, ?~] ->
        raise "paths whose first segment starts with _ or ~ are your beamlet's own " <>
                "(/_mcp, /_live, /_assets) — #{path} cannot be mounted. Use a first " <>
                "segment that starts with a letter or a digit, e.g. " <>
                "#{String.replace_prefix(path, "/" <> segment, "/" <> String.slice(segment, 1..-1//1))}"

      _segment ->
        :ok
    end
  end

  defp first_segment("/" <> rest), do: rest |> String.split("/", parts: 2) |> hd()

  defp reject_prefixed!(path) do
    case strip_prefix(path) do
      nil ->
        :ok

      relative ->
        prefix = prefix()

        raise "paths never include the prefix #{prefix} — #{path} would be served " <>
                "at #{prefix <> path}. Use #{relative}; ~p#{inspect(relative)} in a template " <>
                "or Host.Router.path(#{inspect(relative)}) gives the browser path"
    end
  end

  defp strip_prefix(path) do
    case prefix() do
      "" ->
        nil

      ^path ->
        "/"

      prefix ->
        if String.starts_with?(path, prefix <> "/"),
          do: String.replace_prefix(path, prefix, ""),
          else: nil
    end
  end

  defp validate_action!(action) when is_atom(action) and not is_nil(action), do: :ok

  defp validate_action!(action) do
    raise "the action must be an atom naming a function, e.g. :create — got: #{inspect(action)}"
  end

  defp validate_live_action!(action) when is_atom(action), do: :ok

  defp validate_live_action!(action) do
    raise "the live action must be an atom, e.g. :new — got: #{inspect(action)}"
  end

  defp ensure_defined!(module) when is_atom(module) and not is_nil(module) do
    case Beamlet.Code.manifest() do
      %{^module => _paths} ->
        :ok

      _manifest ->
        if Code.ensure_loaded?(module) do
          raise "only modules defined with define can be mounted — " <>
                  "#{inspect(module)} is part of your beamlet"
        else
          raise "nothing named #{inspect(module)} exists on your beamlet — " <>
                  "define it first"
        end
    end
  end

  defp ensure_defined!(module) do
    raise "Host.Router mounts modules, e.g. Todo.PageLive — got: #{inspect(module)}"
  end

  defp ensure_live!(module) do
    unless function_exported?(module, :__live__, 0) do
      raise "#{inspect(module)} is not a LiveView — write it with `use Host.Web, :live_view`, " <>
              "or mount a controller action with Host.Router.get/post/put/patch/delete"
    end
  end

  defp ensure_controller!(module, action) do
    cond do
      function_exported?(module, :__live__, 0) ->
        raise "#{inspect(module)} is a LiveView — mount it with Host.Router.live/2"

      # `use Phoenix.Controller` leaves no marker like `__live__/0`;
      # `action/2` is the controller pipeline's dispatch hook, which
      # plain plugs never define.
      not function_exported?(module, :action, 2) ->
        raise "#{inspect(module)} is not a Phoenix controller — write it with " <>
                "`use Host.Web, :controller` so its actions can be mounted"

      not function_exported?(module, action, 2) ->
        raise "#{inspect(module)} does not export #{action}/2 — " <>
                "a controller action takes (conn, params)"

      true ->
        :ok
    end
  end

  defp validate_verb!(verb) when verb in @verbs, do: :ok

  defp validate_verb!(verb) do
    raise "the verb must be one of " <>
            Enum.map_join(@verbs, ", ", &inspect/1) <> " — got: #{inspect(verb)}"
  end

  defp call_headers!(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:headers] == [] do
      raise "call takes a headers option, e.g. call(:post, path, data, " <>
              "headers: [{\"x-hub-signature\", sig}]) — got: #{inspect(opts)}"
    end

    headers = Keyword.get(opts, :headers, [])

    unless is_list(headers) and
             Enum.all?(
               headers,
               &match?({name, value} when is_binary(name) and is_binary(value), &1)
             ) do
      raise "headers must be name/value string pairs, e.g. " <>
              "[{\"x-hub-signature\", sig}] — got: #{inspect(headers)}"
    end

    Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp call_body!(_verb, nil, headers), do: {nil, headers}
  defp call_body!(_verb, body, headers) when is_binary(body), do: {body, headers}
  defp call_body!(:get, params, headers) when is_map(params), do: {params, headers}

  defp call_body!(_verb, params, headers) when is_map(params) do
    headers = List.keystore(headers, "content-type", 0, {"content-type", "application/json"})
    {JSON.encode!(params), headers}
  end

  defp call_body!(_verb, data, _headers) do
    raise "data must be a map or a string — got: #{inspect(data)}"
  end

  defp unmount_verb!(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:verb] == [] do
      raise "unmount takes a verb option, e.g. unmount(\"/todos\", verb: :post) — " <>
              "got: #{inspect(opts)}"
    end

    case Keyword.get(opts, :verb) do
      nil ->
        nil

      verb when verb in @verbs ->
        verb

      other ->
        raise "unknown verb #{inspect(other)} — use one of " <>
                Enum.map_join(@verbs, ", ", &inspect/1)
    end
  end

  # ── Config ────────────────────────────────────────────────────────

  defp endpoint, do: Config.web()[:endpoint]

  defp prefix, do: Config.web()[:prefix]

  defp base_url, do: endpoint().url()

  defp browser_path(path) do
    case {prefix(), path} do
      {"", _path} -> path
      {prefix, "/"} -> prefix
      {prefix, _path} -> prefix <> path
    end
  end
end
