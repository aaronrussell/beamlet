defmodule Beamlet.OAuth.Clients do
  @moduledoc """
  How a beamlet learns who a client is: by fetching the client's
  metadata document.

  A client registers with a beamlet without registering. Its client
  id is an https URL on its own domain, and that URL serves a JSON
  document naming the client and the redirect URIs it may be sent
  to. `fetch/1` fetches the document and checks it: the id must be
  an https URL, the document's own `client_id` must equal it, and it
  must list at least one redirect URI. Nothing else in the document
  is read; a display name is only what its author says, so the
  consent page and the token label show the URL's host instead.

  Fetching a URL somebody else chose is how a server gets pointed at
  its own network, so the fetch is guarded: `ReqSSRF` refuses any
  scheme but https, a host written as an address, and a name that
  does not resolve or resolves to a reserved or private address;
  the beamlet itself follows no redirects, gives up after five
  seconds and reads at most 64KB. A fetched document is cached for
  an hour, so the consent page and the token exchange do not fetch
  it again.

  `redirect_uri_allowed?/2` is the matching rule: a redirect URI must
  equal a listed one exactly, except that a listed loopback URI,
  `http://localhost/callback` or `http://127.0.0.1/callback`, matches
  either host on any port, which is what a client that opens a
  listener on the person's machine needs (RFC 8252 § 7.3) and what
  Claude Code sends.
  """

  use GenServer

  require Logger

  @ttl_ms 60 * 60 * 1000
  @max_body 65_536
  @timeout 5_000
  @loopback_hosts ["localhost", "127.0.0.1"]

  @typedoc "What the beamlet keeps of a client metadata document."
  @type document :: %{client_id: String.t(), redirect_uris: [String.t()]}

  @typedoc "Why a client id could not be turned into a document."
  @type reason :: :invalid_client_id | :blocked | :unreachable | :too_large | :invalid_document

  @doc "Starts the cache."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The document behind a client id, fetched and checked, or from the
  cache.

  The reason for a refusal is for the log and the operator, never
  for the page: which names resolve from inside the beamlet's network
  is not the visitor's to learn.
  """
  @spec fetch(term()) :: {:ok, document()} | {:error, reason()}
  def fetch(client_id) when is_binary(client_id) do
    with :ok <- validate_client_id(client_id) do
      case GenServer.call(__MODULE__, {:get, client_id}) do
        {:ok, document} ->
          {:ok, document}

        :miss ->
          case download(client_id) do
            {:ok, document} ->
              GenServer.cast(__MODULE__, {:put, client_id, document})
              {:ok, document}

            {:error, reason} ->
              Logger.warning(
                "could not fetch the client metadata document #{client_id}: #{reason}"
              )

              {:error, reason}
          end
      end
    end
  end

  def fetch(_other), do: {:error, :invalid_client_id}

  @doc "Whether a redirect URI is one the document lists, exactly or by the loopback rule."
  @spec redirect_uri_allowed?(document(), term()) :: boolean()
  def redirect_uri_allowed?(%{redirect_uris: uris}, uri) when is_binary(uri) do
    Enum.any?(uris, fn listed -> listed == uri or loopback_match?(listed, uri) end)
  end

  def redirect_uri_allowed?(_document, _uri), do: false

  @doc "Whether a redirect URI points at the person's own machine."
  @spec loopback?(String.t()) :: boolean()
  def loopback?(uri) when is_binary(uri) do
    match?(%URI{scheme: "http", host: host} when host in @loopback_hosts, URI.parse(uri))
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:get, client_id}, _from, entries) do
    now = System.monotonic_time(:millisecond)

    case Map.fetch(entries, client_id) do
      {:ok, {document, fetched_at}} when now - fetched_at < @ttl_ms ->
        {:reply, {:ok, document}, entries}

      _stale_or_missing ->
        {:reply, :miss, Map.delete(entries, client_id)}
    end
  end

  @impl true
  def handle_cast({:put, client_id, document}, entries) do
    {:noreply, Map.put(entries, client_id, {document, System.monotonic_time(:millisecond)})}
  end

  defp validate_client_id(client_id) do
    case URI.new(client_id) do
      {:ok, %URI{scheme: "https", host: host, fragment: nil}}
      when is_binary(host) and host != "" ->
        :ok

      _other ->
        {:error, :invalid_client_id}
    end
  end

  defp download(client_id) do
    request =
      [
        url: client_id,
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: @timeout,
        into: &collect/2
      ]
      |> Req.new()
      |> ReqSSRF.attach(schemes: ["https"], allow_ip_address: false)
      |> Req.merge(req_options())

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: :too_large}} -> {:error, :too_large}
      {:ok, %Req.Response{status: 200, body: body}} -> parse(client_id, body)
      {:ok, %Req.Response{}} -> {:error, :unreachable}
      {:error, %ReqSSRF.BlockedError{}} -> {:error, :blocked}
      {:error, _exception} -> {:error, :unreachable}
    end
  end

  defp collect({:data, _data}, {request, %Req.Response{body: :too_large} = response}) do
    {:halt, {request, response}}
  end

  defp collect({:data, data}, {request, %Req.Response{body: body} = response}) do
    body = body <> data

    if byte_size(body) > @max_body,
      do: {:halt, {request, %{response | body: :too_large}}},
      else: {:cont, {request, %{response | body: body}}}
  end

  defp parse(client_id, body) do
    with {:ok, %{"client_id" => ^client_id, "redirect_uris" => [_ | _] = uris}} <-
           Jason.decode(body),
         true <- Enum.all?(uris, &is_binary/1) do
      {:ok, %{client_id: client_id, redirect_uris: uris}}
    else
      _other -> {:error, :invalid_document}
    end
  end

  defp loopback_match?(listed, presented) do
    with %URI{scheme: "http", host: host, path: path, query: query} <- URI.parse(listed),
         true <- host in @loopback_hosts,
         %URI{scheme: "http", host: other, path: ^path, query: ^query} <- URI.parse(presented) do
      other in @loopback_hosts
    else
      _other -> false
    end
  end

  # The test seam: config/test.exs points the request at a Req.Test
  # stub and the address check at a resolver that never touches DNS.
  defp req_options do
    :beamlet
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
