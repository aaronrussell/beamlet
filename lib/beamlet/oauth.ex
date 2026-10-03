defmodule Beamlet.OAuth do
  @moduledoc """
  How a chat client connects to a beamlet by OAuth, with no token to
  paste.

  A client presents a token one of two ways. Code, and any client
  that takes a header, sends a `cli` token from `beamlet tokens.create`
  as `Authorization: Bearer <secret>`. A hosted chat client that
  connects by OAuth or not at all, and any client that offers it,
  runs the OAuth flow instead: the owner signs in, picks a policy and
  consents, and the client ends up holding an `oauth` token
  (`Beamlet.Token`). Both kinds are the same delegation under a
  policy; OAuth is how the second one is handed over.

  A beamlet is its own authorization server, so there is no identity
  provider to sign up for and nothing to configure. It plays both
  OAuth roles at one origin. As the resource server it protects
  `/beamlet/mcp`, and answers a request with no token with a 401
  whose challenge names the protected resource metadata document.
  As the authorization server it serves the login, the consent page
  at `/beamlet/authorize` and the token endpoint at `/beamlet/token`,
  and names them in the authorization server metadata document. Both
  documents are served at the well-known paths the specs fix at the
  root, and their contents are this module's functions.

  ## The flow

  1. The client calls `/beamlet/mcp` without a token, reads the two
     metadata documents the 401 points it to, and sends the browser to
     `/beamlet/authorize`.
  2. A signed-out browser signs in first, so the beamlet knows the
     owner is the one consenting.
  3. The client identifies itself by an https URL serving its
     metadata document. The beamlet fetches it, checks the redirect
     URI against what it lists, and shows the consent page: the client
     by its URL's host, and every declared policy with `default`
     preselected.
  4. Allowing stores a single-use code for this client, redirect URI
     and policy, and sends the browser back to the client. Denying
     sends it back with `access_denied`.
  5. The client redeems the code at `/beamlet/token`, proving with
     PKCE that it started the flow, for an access token and a refresh
     token. Later it redeems the refresh token for a new pair, and the
     old one stops working.

  ## Lifetimes

  An access token lives a day (`access_ttl/0`), and a refresh token
  thirty days from the last refresh (`refresh_ttl/0`). Every refresh
  sets both afresh, so a client in regular use never asks the owner
  to consent again, and one left unused for thirty days does. A code
  lives ten minutes, in memory: a restart in the middle of a
  connection means clicking connect again. A client's metadata
  document is cached for an hour.

  ## Managing OAuth tokens

  `beamlet tokens` lists `oauth` tokens beside `cli` ones, labelled by
  the client's host, and `beamlet tokens.delete` revokes one at once.
  Neither the client nor the policy can be edited: the client is
  verified identity and the policy was chosen at consent, so the
  answer is to delete the token and connect again. No scopes are
  advertised and none mean anything; what a token may do is its
  policy.

  ## The beamlet's URL

  Every URL here, the issuer, the resource and the endpoints, is
  built at request time from the endpoint's `url` config, the way
  `Host.Router.url/1` builds an agent's. A beamlet reached at
  `https://beamlet.example` protects `https://beamlet.example/beamlet/mcp`,
  and a client asking for a token for any other address is refused,
  so the endpoint's `url` must be the address clients use:
  `BEAMLET_URL` for the standalone server.
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

  # Both expiries counted from now, as the attrs minting and rotation
  # take.
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
