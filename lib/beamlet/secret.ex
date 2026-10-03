defmodule Beamlet.Secret do
  @moduledoc false

  # The random secrets Beamlet hands out, tokens, sessions and OAuth
  # codes, and the hash it stores in their place. A fast hash is right
  # for a secret with 256 bits of entropy.

  @doc "A new secret: 32 random bytes, URL-safe Base64."
  @spec generate() :: String.t()
  def generate, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "The SHA-256 a secret is stored and looked up by."
  @spec hash(String.t()) :: binary()
  def hash(secret), do: :crypto.hash(:sha256, secret)
end
