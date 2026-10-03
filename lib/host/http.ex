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

  To stream a large body, pass an `into` function; `into: :self` is
  refused. The function receives each chunk and returns
  `{:cont, acc}` to go on or `{:halt, acc}` to stop:

      Host.HTTP.get!(url,
        into: fn {:data, chunk}, acc ->
          Host.File.write!("export.csv", chunk, [:append])
          {:cont, acc}
        end
      )

  Requests reach the public internet. One to a host that is
  loopback, on a private network, link-local or another reserved
  address, through a redirect included, comes back as
  `{:error, %Host.HTTP.BlockedError{}}`. To call a route your beamlet
  serves, use `Host.Router.call/4`, which runs it in your process.

  Options that would send a request anywhere but the network, or keep
  it on disk, are refused with an `ArgumentError` naming the option:
  `plug`, `adapter`, `unix_socket`, `connect_options`, `finch` and
  `finch_request`, the disk cache, and `.netrc` credentials. `Req`'s
  own functions are not available to your code; these are how
  requests leave your beamlet.
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
  `request(url: url, method: :options)`.

  The method defaults to GET.
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
  # plugin runs, and Req refuses any option it does not know. The guard
  # and the seam are added after the check: they are ours.
  defp build(request, options) do
    Req.new()
    |> Req.merge(request_options(request) ++ options)
    |> refuse_bypass!()
    |> Req.Request.append_request_steps(outbound_guard: &guard/1)
    |> Req.merge(req_options())
  end

  defp request_options(url) when is_binary(url) or is_struct(url, URI), do: [url: url]
  defp request_options(options) when is_list(options), do: options

  defp request_options(other) do
    raise ArgumentError,
          "Host.HTTP takes a URL or a keyword list of options, got: #{inspect(other)}"
  end

  # ── The options that bypass the guard ────────────────────────────

  # Each sends the request somewhere the guard never checks, or keeps
  # it on disk. Every other option is Req's to validate.
  @bypass [:connect_options, :finch, :finch_request, :plug, :unix_socket]

  defp refuse_bypass!(%Req.Request{} = req) do
    Enum.each(req.options, &check_option!/1)
    if req.adapter != Req.Finch, do: refuse!(":adapter", connection_copy())
    check_into!(req.into)
    req
  end

  defp check_option!({key, _value}) when key in @bypass,
    do: refuse!(":#{key}", connection_copy())

  defp check_option!({key, _value}) when key in [:cache, :cache_dir] do
    refuse!(
      ":#{key}",
      "responses are not cached to disk; keep what you need in Host.KV or Host.File"
    )
  end

  defp check_option!({:auth, :netrc}), do: refuse_netrc!(:netrc)
  defp check_option!({:auth, {:netrc, _path} = netrc}), do: refuse_netrc!(netrc)
  defp check_option!(_option), do: :ok

  @spec refuse_netrc!(:netrc | {:netrc, term()}) :: no_return()
  defp refuse_netrc!(netrc) do
    refuse!(
      ":auth #{inspect(netrc)}",
      "credentials are passed, not read from files: auth: {:bearer, token} or " <>
        "auth: {:basic, \"user:password\"}"
    )
  end

  defp check_into!(:self) do
    refuse!(
      ":into :self",
      "stream with a function: into: fn {:data, chunk}, acc -> {:cont, acc} end"
    )
  end

  defp check_into!(_into), do: :ok

  defp connection_copy,
    do: "requests go over the network through your beamlet's own connection pool"

  @spec refuse!(String.t(), String.t()) :: no_return()
  defp refuse!(what, why) do
    raise ArgumentError, "Host.HTTP does not accept #{what}: #{why}"
  end

  # ── The outbound guard ────────────────────────────────────────────

  # A request step, so it sees the URL after base_url and params, and
  # Req runs it again for every redirect. A halt here skips the error
  # steps, so a refused request is never retried.
  defp guard(%Req.Request{url: url} = req) do
    if allowed?(url.host) do
      req
    else
      case ReqSSRF.check(url, check_options()) do
        :ok -> req
        {:error, reason} -> Req.Request.halt(req, blocked(url, reason))
      end
    end
  end

  # URI keeps the userinfo in authority too, so the URL is rebuilt
  # rather than edited.
  defp blocked(url, reason) do
    url = URI.new!(URI.to_string(%{url | userinfo: nil}))
    %Host.HTTP.BlockedError{url: url, reason: reason}
  end

  defp allowed?(host) when is_binary(host) do
    allow = Beamlet.Config.http()[:allow]

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> Enum.any?(allow, &address_in?(address, &1))
      {:error, _} -> Enum.any?(allow, &(String.downcase(&1) == String.downcase(host)))
    end
  end

  defp allowed?(_host), do: false

  defp address_in?(address, entry) do
    case :inet.parse_address(String.to_charlist(entry)) do
      {:ok, ^address} ->
        true

      {:ok, _other} ->
        false

      {:error, _} ->
        case InetCidr.parse_cidr(entry) do
          {:ok, cidr} -> InetCidr.contains?(cidr, address)
          {:error, _} -> false
        end
    end
  end

  # The test seams: config/test.exs points requests at a Req.Test stub
  # and name resolution at a resolver that never touches DNS.
  defp check_options do
    case Keyword.fetch(seam(), :resolver) do
      {:ok, resolver} -> [resolver: resolver]
      :error -> []
    end
  end

  defp req_options, do: Keyword.get(seam(), :req_options, [])

  defp seam, do: Application.get_env(:beamlet, __MODULE__, [])
end
