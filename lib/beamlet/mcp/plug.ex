defmodule Beamlet.MCP.Plug do
  @moduledoc """
  The authenticated entry to a beamlet's MCP server.

  A host mounts it where the server should live:

      forward "/mcp", Beamlet.MCP.Plug

  Every request carries one of the beamlet's own tokens as a bearer
  credential:

      Authorization: Bearer <token>

  The plug turns that secret into its token and user, puts the
  `Beamlet.Principal` in the conn's assigns under `:principal`, and
  hands the request to the MCP transport, which carries the assigns
  into the frame every server callback receives. Identity is per
  request: nothing is remembered between one request and the next. A
  request with no token, another scheme, or a secret that matches no
  token is a 401 with a `Bearer` challenge.
  """

  @behaviour Plug

  import Plug.Conn

  alias Anubis.Server.Transport.StreamableHTTP
  alias Beamlet.Principal
  alias Beamlet.Users

  @body "A beamlet token is required: Authorization: Bearer <token>"

  @impl true
  def init(_opts), do: StreamableHTTP.Plug.init(server: Beamlet.MCP.Server)

  @impl true
  def call(conn, transport_opts) do
    with {:ok, secret} <- bearer(conn),
         {:ok, token} <- Users.authenticate(secret) do
      conn
      |> assign(:principal, Principal.from_token(token))
      |> StreamableHTTP.Plug.call(transport_opts)
    else
      {:error, _reason} -> unauthorized(conn)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> secret] -> {:ok, secret}
      _other -> {:error, :no_token}
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_resp_content_type("text/plain")
    |> send_resp(401, @body)
  end
end
