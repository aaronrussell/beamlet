defmodule Host.HTTP do
  @moduledoc """
  HTTP requests with Req's arguments, answered with a `Req.Response`.

  Each function takes the same arguments as its namesake in `Req`:
  `get/2` as `Req.get/2`, `request/2` as `Req.request/2`, a URL or a
  keyword list first and options after. Req's documentation describes
  the options, and the response's helpers work on the result. A
  function returns `{:ok, response}` or `{:error, exception}`; its
  bang variant returns the response or raises the exception.

      Host.HTTP.get!("https://api.github.com/repos/elixir-lang/elixir").body["stargazers_count"]

      case Host.HTTP.post("https://example.com/hooks", json: %{event: "deployed"}) do
        {:ok, %Req.Response{status: 200}} -> :ok
        {:ok, response} -> {:error, response.status}
        {:error, exception} -> {:error, Exception.message(exception)}
      end

  To stream a large body, pass an `into` function. It receives each
  chunk and returns `{:cont, acc}` to go on or `{:halt, acc}` to stop:

      Host.HTTP.get!(url,
        into: fn {:data, chunk}, acc ->
          Host.File.write!("export.csv", chunk, [:append])
          {:cont, acc}
        end
      )

  Options that would reach past the network are refused with an
  `ArgumentError` naming the option: `plug`, `adapter`, `unix_socket`
  and the connection settings, the disk cache, `.netrc` credentials,
  `{mod, fun, args}` values, module decoders, and bodies streamed
  from files. `Req`'s own functions are not available to your code;
  these are how requests leave your beamlet.
  """

  @typedoc "A URL, or a keyword list of options that includes `:url`."
  @type request :: String.t() | URI.t() | keyword()

  @typedoc "The response, or the exception that ended the request."
  @type result :: {:ok, Req.Response.t()} | {:error, Exception.t()}

  @doc """
  Makes a GET request, e.g. `get("https://example.com", params: [q: "elixir"])`.
  """
  @spec get(request(), keyword()) :: result()
  def get(request, options \\ []), do: run(request, options, :get)

  @doc "Like `get/2`, returning the response or raising."
  @spec get!(request(), keyword()) :: Req.Response.t()
  def get!(request, options \\ []), do: run!(request, options, :get)

  @doc """
  Makes a POST request, e.g. `post(url, json: %{name: "beamlet"})`.
  """
  @spec post(request(), keyword()) :: result()
  def post(request, options \\ []), do: run(request, options, :post)

  @doc "Like `post/2`, returning the response or raising."
  @spec post!(request(), keyword()) :: Req.Response.t()
  def post!(request, options \\ []), do: run!(request, options, :post)

  @doc "Makes a PUT request."
  @spec put(request(), keyword()) :: result()
  def put(request, options \\ []), do: run(request, options, :put)

  @doc "Like `put/2`, returning the response or raising."
  @spec put!(request(), keyword()) :: Req.Response.t()
  def put!(request, options \\ []), do: run!(request, options, :put)

  @doc "Makes a PATCH request."
  @spec patch(request(), keyword()) :: result()
  def patch(request, options \\ []), do: run(request, options, :patch)

  @doc "Like `patch/2`, returning the response or raising."
  @spec patch!(request(), keyword()) :: Req.Response.t()
  def patch!(request, options \\ []), do: run!(request, options, :patch)

  @doc "Makes a DELETE request."
  @spec delete(request(), keyword()) :: result()
  def delete(request, options \\ []), do: run(request, options, :delete)

  @doc "Like `delete/2`, returning the response or raising."
  @spec delete!(request(), keyword()) :: Req.Response.t()
  def delete!(request, options \\ []), do: run!(request, options, :delete)

  @doc "Makes a HEAD request."
  @spec head(request(), keyword()) :: result()
  def head(request, options \\ []), do: run(request, options, :head)

  @doc "Like `head/2`, returning the response or raising."
  @spec head!(request(), keyword()) :: Req.Response.t()
  def head!(request, options \\ []), do: run!(request, options, :head)

  @doc """
  Makes a request with the method in the options, e.g.
  `request(url: url, method: :options)`. The method defaults to GET.
  """
  @spec request(request(), keyword()) :: result()
  def request(request, options \\ []), do: run(request, options)

  @doc "Like `request/2`, returning the response or raising."
  @spec request!(request(), keyword()) :: Req.Response.t()
  def request!(request, options \\ []), do: run!(request, options)

  defp run!(request, options, method \\ nil) do
    case run(request, options, method) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  defp run(request, options, method \\ nil) do
    options =
      case method do
        nil -> options
        method -> Keyword.put(options, :method, method)
      end

    request
    |> build(options)
    |> Req.request()
  end

  # The agent's options are checked on the built struct, where Req has
  # already turned them into what its steps and adapter will act on
  # (plug: becomes the adapter, a URL's userinfo becomes auth). Starting
  # from a bare Req.new() means plugins: is refused by merge before any
  # plugin runs. The seam is merged after the check: it is ours.
  defp build(request, options) do
    Req.new()
    |> Req.merge(request_options(request) ++ options)
    |> validate!()
    |> Req.merge(req_options())
    |> wrap_funs()
  end

  defp request_options(url) when is_binary(url) or is_struct(url, URI), do: [url: url]
  defp request_options(options) when is_list(options), do: options

  defp request_options(other) do
    raise ArgumentError,
          "Host.HTTP takes a URL or a keyword list of options, got: #{inspect(other)}"
  end

  # ── The check ─────────────────────────────────────────────────────

  # Fails closed: an option Req adds in a later version is refused
  # until it earns a ruling here.
  @any_value [
    :checksum,
    :compress_body,
    :compressed,
    :decode_body,
    :decode_json,
    :form,
    :http_errors,
    :inet6,
    :json,
    :max_redirects,
    :max_retries,
    :params,
    :path_params,
    :path_params_style,
    :range,
    :raw,
    :receive_timeout,
    :redirect,
    :redirect_log_level,
    :redirect_trusted,
    :request_timeout,
    :retry_log_level,
    :user_agent
  ]

  @shaped [:auth, :aws_sigv4, :base_url, :decoders, :form_multipart, :retry, :retry_delay]

  @connection [
    :connect_options,
    :finch,
    :finch_private,
    :finch_request,
    :plug,
    :pool_max_idle_time,
    :pool_timeout,
    :unix_socket
  ]

  @renamed %{follow_redirects: :redirect, location_trusted: :redirect_trusted}

  @builtin_decoders [:json, :json_api, :zip, :tar, :tgz, :gz, :zst, :csv]

  defp validate!(%Req.Request{} = req) do
    Enum.each(req.options, &check_option!/1)
    if req.adapter != Req.Finch, do: refuse!(":adapter", connection_copy())
    check_into!(req.into)
    check_body!(":body", req.body)
    req
  end

  defp check_option!({key, _value}) when key in @any_value, do: :ok

  defp check_option!({:base_url, url})
       when is_binary(url) or is_struct(url, URI) or is_function(url, 0),
       do: :ok

  defp check_option!({:auth, auth}) when is_binary(auth), do: :ok

  defp check_option!({:auth, {kind, credential}})
       when kind in [:basic, :bearer, :digest] and is_binary(credential),
       do: :ok

  defp check_option!({:auth, :netrc}), do: refuse_netrc!(:netrc)
  defp check_option!({:auth, {:netrc, _path} = netrc}), do: refuse_netrc!(netrc)

  defp check_option!({:aws_sigv4, aws}) when is_list(aws) or is_map(aws), do: :ok
  defp check_option!({:decoders, false}), do: :ok

  defp check_option!({:decoders, decoders}) when is_list(decoders),
    do: Enum.each(decoders, &check_decoder!/1)

  defp check_option!({:form_multipart, parts}) when is_list(parts) or is_map(parts),
    do: Enum.each(parts, &check_part!/1)

  defp check_option!({:retry, retry})
       when retry in [false, :safe_transient, :transient] or is_function(retry, 2),
       do: :ok

  defp check_option!({:retry_delay, delay}) when is_integer(delay) or is_function(delay, 1),
    do: :ok

  defp check_option!({key, _value}) when key in @connection,
    do: refuse!(":#{key}", connection_copy())

  defp check_option!({key, _value}) when key in [:cache, :cache_dir] do
    refuse!(
      ":#{key}",
      "responses are not cached to disk; keep what you need in Host.KV or Host.File"
    )
  end

  defp check_option!({key, _value}) when is_map_key(@renamed, key),
    do: refuse!(":#{key}", "it is now :#{@renamed[key]}")

  defp check_option!({:redact_auth, _value}),
    do: refuse!(":redact_auth", "it has no effect; leave it out")

  defp check_option!({key, {mod, fun, args}})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    refuse!(
      ":#{key} as {mod, fun, args}",
      "pass the value itself, or a function that returns it"
    )
  end

  defp check_option!({key, value}) when key in @shaped do
    refuse!(
      ":#{key} #{inspect(value)}",
      "Req's documentation for :#{key} lists the values it takes"
    )
  end

  defp check_option!({key, _value}),
    do: refuse!(":#{key}", "it is not one of the Req options Host.HTTP passes on")

  @spec refuse_netrc!(:netrc | {:netrc, term()}) :: no_return()
  defp refuse_netrc!(netrc) do
    refuse!(
      ":auth #{inspect(netrc)}",
      "credentials are passed, not read from files: auth: {:bearer, token} or " <>
        "auth: {:basic, \"user:password\"}"
    )
  end

  defp check_decoder!(format) when format in @builtin_decoders, do: :ok

  defp check_decoder!({format, codec})
       when is_atom(format) and (codec in @builtin_decoders or is_function(codec, 1)),
       do: :ok

  defp check_decoder!(decoder) do
    refuse!(
      "decoder #{inspect(decoder)}",
      "a decoder is one of Req's built-in formats or a function, e.g. " <>
        "decoders: [ics: fn body -> {:ok, parse(body)} end]"
    )
  end

  defp check_part!({_name, {value, opts}}) when is_list(opts),
    do: check_body!(":form_multipart", value)

  defp check_part!({_name, value}), do: check_body!(":form_multipart", value)

  defp check_into!(nil), do: :ok
  defp check_into!(fun) when is_function(fun, 2), do: :ok

  defp check_into!(into) do
    refuse!(
      ":into #{inspect(into)}",
      "stream with a function: into: fn {:data, chunk}, acc -> {:cont, acc} end"
    )
  end

  defp check_body!(what, %module{}) when module in [File.Stream, IO.Stream] do
    refuse!(
      "#{what} streamed from a file",
      "read the file first and send its contents, e.g. body: Host.File.read!(path)"
    )
  end

  defp check_body!(_what, _body), do: :ok

  defp connection_copy,
    do: "requests go over the network through your beamlet's own connection pool"

  @spec refuse!(String.t(), String.t()) :: no_return()
  defp refuse!(what, why) do
    raise ArgumentError, "Host.HTTP does not accept #{what}: #{why}"
  end

  # ── Funs Req hands the request to ─────────────────────────────────

  # Req passes the live request to an into function and a retry
  # function. Its step lists hold Req's own step funs, which retry,
  # redirect, read files or call {mod, fun, args} when called by hand,
  # so the agent's function sees the request without them, and an into
  # function's returned request is dropped for ours.
  defp wrap_funs(req), do: req |> wrap_into() |> wrap_retry()

  defp wrap_into(%Req.Request{into: into} = req) when is_function(into, 2) do
    wrapped = fn chunk, {live, response} ->
      {command, {_request, returned}} = into.(chunk, {strip(live), response})
      {command, {live, returned}}
    end

    %{req | into: wrapped}
  end

  defp wrap_into(req), do: req

  defp wrap_retry(%Req.Request{options: %{retry: retry}} = req) when is_function(retry, 2) do
    Req.Request.put_option(req, :retry, fn live, outcome -> retry.(strip(live), outcome) end)
  end

  defp wrap_retry(req), do: req

  defp strip(req), do: %{req | request_steps: [], response_steps: [], error_steps: []}

  # The test seam: config/test.exs points requests at a Req.Test stub.
  defp req_options do
    :beamlet
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
