defmodule Beamlet.Secret do
  @moduledoc false

  # The random secrets Beamlet hands out, tokens, sessions and OAuth
  # codes, and the hash it stores in their place. A fast hash is right
  # for a secret with 256 bits of entropy.

  @spec generate() :: String.t()
  def generate, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @spec hash(String.t()) :: binary()
  def hash(secret), do: :crypto.hash(:sha256, secret)
end
