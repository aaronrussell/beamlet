defmodule Beamlet.OAuth.Codes do
  @moduledoc """
  The pending authorization codes: what the consent page stored and
  the token endpoint has not yet redeemed.

  A code stands for one consent: this user, this policy, this client,
  this redirect URI, the PKCE challenge the client committed to, and
  the resource and scope it asked for. It lives ten minutes, is
  redeemed once, since `take/1` deletes it, and is worthless without
  the PKCE secret. Codes live in memory: a restart mid-flow means the
  client hears `invalid_grant` and the person clicks connect again.
  """

  use GenServer

  @ttl 600
  @sweep_ms 60_000

  @typedoc "What a code stands for."
  @type entry :: %{
          user_id: pos_integer(),
          policy: String.t(),
          client_id: String.t(),
          redirect_uri: String.t(),
          code_challenge: String.t(),
          resource: String.t() | nil,
          scope: String.t() | nil
        }

  @doc "Starts the store. `ttl:` is a code's life in seconds, ten minutes by default."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Stores an entry and returns the code that redeems it."
  @spec store(entry(), GenServer.server()) :: String.t()
  def store(entry, server \\ __MODULE__), do: GenServer.call(server, {:store, entry})

  @doc "Redeems a code: its entry, deleted on the way out, or `:error` for an unknown, used or expired one."
  @spec take(term(), GenServer.server()) :: {:ok, entry()} | :error
  def take(code, server \\ __MODULE__)
  def take(code, server) when is_binary(code), do: GenServer.call(server, {:take, code})
  def take(_other, _server), do: :error

  @impl true
  def init(opts) do
    schedule_sweep()
    {:ok, %{ttl_ms: Keyword.get(opts, :ttl, @ttl) * 1000, codes: %{}}}
  end

  @impl true
  def handle_call({:store, entry}, _from, state) do
    code = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    expires_at = System.monotonic_time(:millisecond) + state.ttl_ms
    codes = Map.put(state.codes, code, Map.put(entry, :expires_at, expires_at))
    {:reply, code, %{state | codes: codes}}
  end

  def handle_call({:take, code}, _from, state) do
    {entry, codes} = Map.pop(state.codes, code)

    reply =
      case entry do
        %{expires_at: expires_at} ->
          if expired?(expires_at), do: :error, else: {:ok, Map.delete(entry, :expires_at)}

        nil ->
          :error
      end

    {:reply, reply, %{state | codes: codes}}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()
    codes = Map.reject(state.codes, fn {_code, entry} -> expired?(entry.expires_at) end)
    {:noreply, %{state | codes: codes}}
  end

  defp expired?(expires_at), do: System.monotonic_time(:millisecond) >= expires_at

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
