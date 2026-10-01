defmodule Host.HTTP.BlockedError do
  @moduledoc """
  The error for a request `Host.HTTP` will not send.

  `Host.HTTP` reaches the public internet. A request whose host is
  loopback, on a private network, link-local or another reserved
  address, or whose host does not resolve, comes back as
  `{:error, %Host.HTTP.BlockedError{}}`, and the bang variant raises
  it. A redirect is checked the same way, so a public URL that
  redirects to a private one is refused at the redirect.

  `url` is the URL refused, without any credentials it carried, and
  `reason` an atom saying why, such as `:reserved_address` or
  `:unresolvable_host`.

      {:error, %Host.HTTP.BlockedError{reason: :reserved_address}} =
        Host.HTTP.get("http://localhost:4000/")
  """

  defexception [:url, :reason]

  @typedoc "The URL refused, without credentials, and why."
  @type t :: %__MODULE__{url: URI.t(), reason: atom()}

  @impl Exception
  def message(%__MODULE__{url: url, reason: :reserved_address}) do
    "Host.HTTP does not reach #{url}: its host is loopback, on a private network, " <>
      "link-local or another reserved address, not one on the public internet"
  end

  def message(%__MODULE__{url: url, reason: reason}) do
    Exception.message(%ReqSSRF.BlockedError{url: url, reason: reason})
  end
end
