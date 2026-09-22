defmodule Beamlet.MCP.Plug do
  @moduledoc """
  The authenticated entry to a beamlet's MCP server.

  `Beamlet.Router` mounts it at `/beamlet/mcp`, so a host that forwards to
  that router has it:

      forward "/", Beamlet.Router

  Every request carries one of the beamlet's own tokens as a bearer
  credential:

      Authorization: Bearer <token>

  The plug turns that secret into its token and user, puts the
  `Beamlet.Principal` in the conn's assigns under `:principal`, and
  hands the request to the MCP transport, which carries the assigns
  into the frame every server callback receives. Identity is per
  request: nothing is remembered between one request and the next.

  This is where the beamlet's two OAuth roles meet the transport
  (`Beamlet.OAuth`). A request with no token, another scheme, a secret
  that matches no token, or an `oauth` token past its expiry is a 401
  whose `Bearer` challenge names the protected resource metadata
  document, which is how a chat client discovers that this beamlet is
  its own authorization server and starts the flow. A token naming a
  policy the beamlet does not declare, one removed from config since
  the token was created, is a 403 with a line naming the token and
  the policy: the credential is real but insufficient. So is a token
  naming a policy outside its user's current list
  (`Beamlet.Users.policies/1`), which is how narrowing a user's
  policies takes effect on their existing tokens at once.
  """

  @behaviour Plug

  import Plug.Conn

  alias Anubis.Server.Transport.StreamableHTTP
  alias Beamlet.OAuth
  alias Beamlet.Policies
  alias Beamlet.Principal
  alias Beamlet.Token
  alias Beamlet.Users

  @body "A beamlet token is required: Authorization: Bearer <token>"

  @impl true
  def init(_opts), do: StreamableHTTP.Plug.init(server: Beamlet.MCP.Server)

  @impl true
  def call(conn, transport_opts) do
    with {:ok, secret} <- bearer(conn),
         {:ok, token} <- Users.authenticate(secret),
         :ok <- declared(token),
         :ok <- granted(token) do
      conn
      |> assign(:principal, Principal.from_token(token))
      |> StreamableHTTP.Plug.call(transport_opts)
    else
      {:error, {:no_policy, token}} -> forbidden(conn, token, :undeclared)
      {:error, {:not_granted, token}} -> forbidden(conn, token, :not_granted)
      {:error, _reason} -> unauthorized(conn)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> secret] -> {:ok, secret}
      _other -> {:error, :no_token}
    end
  end

  defp declared(%Token{policy: policy} = token) do
    case Policies.fetch(policy) do
      {:ok, _policy} -> :ok
      {:error, :not_found} -> {:error, {:no_policy, token}}
    end
  end

  defp granted(%Token{policy: policy, user: user} = token) do
    if policy in Users.policies(user), do: :ok, else: {:error, {:not_granted, token}}
  end

  defp unauthorized(conn) do
    challenge =
      ~s(Bearer realm="beamlet", resource_metadata="#{OAuth.resource_metadata_url()}")

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> put_resp_content_type("text/plain")
    |> send_resp(401, @body)
  end

  defp forbidden(conn, token, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(
      403,
      "Token #{Token.label(token)} names policy #{token.policy}, " <> why(token, reason)
    )
  end

  defp why(_token, :undeclared), do: "which this beamlet does not declare."

  defp why(%Token{user: user}, :not_granted) do
    "which its user #{user.name} may not use (#{user.name}'s policies: " <>
      Enum.join(user.policies, ", ") <> ")."
  end
end
