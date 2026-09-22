defmodule Beamlet.TestResolver do
  @moduledoc """
  The name resolver the suite hands `ReqSSRF` in place of DNS: every
  host is public except `localhost`, which is loopback as it is
  everywhere, and a name under `internal.test`, which resolves to a
  private address so a test can see the guard refuse it.
  """

  @public {93, 184, 216, 34}
  @private {10, 0, 0, 5}
  @loopback {127, 0, 0, 1}

  @doc "Mirrors `:inet.getaddrs/3`: an A record per host, no AAAA records."
  @spec resolve(charlist(), :inet | :inet6, timeout()) ::
          {:ok, [:inet.ip_address()]} | {:error, :nxdomain}
  def resolve(~c"localhost", :inet, _timeout), do: {:ok, [@loopback]}

  def resolve(host, :inet, _timeout) do
    if List.to_string(host) |> String.ends_with?("internal.test"),
      do: {:ok, [@private]},
      else: {:ok, [@public]}
  end

  def resolve(_host, :inet6, _timeout), do: {:error, :nxdomain}
end
