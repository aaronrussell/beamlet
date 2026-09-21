defmodule Beamlet.OAuth do
  @moduledoc """
  The facts a beamlet publishes about itself as an OAuth server: its
  issuer, the resource it protects, and the two metadata documents a
  client reads before it connects.

  A beamlet plays both OAuth roles at one origin. As the resource
  server it protects `/beamlet/mcp` and, on a request with no token,
  names the protected resource metadata document in the 401 challenge
  (`Beamlet.MCP.Plug`). As the authorization server it publishes its
  endpoints in the authorization server metadata document. Both
  documents are served by `Beamlet.OAuth.MetadataController` at the
  well-known paths the specs fix at the root.

  Every URL here is built from the endpoint's `url` config at request
  time, the way `Host.Router.url/1` builds an agent's, so a beamlet
  reached at `https://beamlet.example` protects
  `https://beamlet.example/beamlet/mcp` and nothing needs configuring
  twice.
  """

  alias Beamlet.Config

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
