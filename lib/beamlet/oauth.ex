defmodule Beamlet.OAuth do
  @moduledoc """
  How chat clients connect to your beamlet with OAuth.

  You give the client your beamlet's MCP URL, such as
  `https://beamlet.example/beamlet/mcp`. The client sends you to your
  beamlet, where you sign in and choose a policy. That is the whole
  setup: there is no client to register and no secret to copy. The
  home page has the steps for each client. Clients without OAuth use
  a token from `beamlet tokens.create` instead.

  The client receives an access token that lives for a day, and
  refreshes it when it runs out. Each refresh keeps the connection
  for another thirty days, so a client you use at least once a month
  never asks you to sign in again.

  `beamlet tokens` lists these tokens by the client's host. To cut a
  client off, or to change its policy, delete its token and connect
  again.

  Every OAuth URL is built from the address your beamlet is reached
  at: `BEAMLET_URL` on the standalone server, or the endpoint's `url`
  config when embedded. If that address is wrong, clients cannot
  connect.
  """

  alias Beamlet.Config

  @access_ttl 24 * 60 * 60
  @refresh_ttl 30 * 24 * 60 * 60

  @doc "How long an access token lives, in seconds: a day."
  @spec access_ttl() :: pos_integer()
  def access_ttl, do: @access_ttl

  @doc "How long a refresh token lives, in seconds: thirty days from the last refresh."
  @spec refresh_ttl() :: pos_integer()
  def refresh_ttl, do: @refresh_ttl

  @doc false
  @spec expiries() :: %{expires_at: DateTime.t(), refresh_expires_at: DateTime.t()}
  def expiries do
    now = DateTime.utc_now(:second)

    %{
      expires_at: DateTime.add(now, @access_ttl, :second),
      refresh_expires_at: DateTime.add(now, @refresh_ttl, :second)
    }
  end

  # A request parameter as the endpoints read it: the value when it is
  # a non-empty string, nil otherwise, so a missing, empty or malformed
  # parameter is one case.
  @doc false
  @spec present(term()) :: String.t() | nil
  def present(value) when is_binary(value) and value != "", do: value
  def present(_other), do: nil

  @doc "The beamlet's origin, which is also its OAuth issuer."
  @spec issuer() :: String.t()
  def issuer, do: Config.web()[:endpoint].url()

  @doc "The MCP URL a token is for, byte for byte what a client sends as `resource`."
  @spec resource() :: String.t()
  def resource, do: issuer() <> "/beamlet/mcp"

  @doc "The protected resource metadata URL the 401 challenge names."
  @spec resource_metadata_url() :: String.t()
  def resource_metadata_url, do: issuer() <> "/.well-known/oauth-protected-resource"

  @doc "The protected resource metadata document (RFC 9728): the resource and its authorization server, this origin."
  @spec protected_resource_metadata() :: map()
  def protected_resource_metadata do
    %{
      "resource" => resource(),
      "authorization_servers" => [issuer()],
      "bearer_methods_supported" => ["header"]
    }
  end

  @doc """
  The authorization server metadata document (RFC 8414): the two
  endpoints and what the flow supports. No scopes are advertised; the
  policy is chosen on the consent page instead.
  """
  @spec authorization_server_metadata() :: map()
  def authorization_server_metadata do
    issuer = issuer()

    %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/beamlet/authorize",
      "token_endpoint" => issuer <> "/beamlet/token",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "client_id_metadata_document_supported" => true,
      "authorization_response_iss_parameter_supported" => true
    }
  end
end
