defmodule Beamlet.OAuth.MetadataController do
  @moduledoc """
  Serves the two OAuth discovery documents at the root, where the
  specs fix them.

  The protected resource document answers at
  `/.well-known/oauth-protected-resource`, the URL the 401 challenge
  names, and at `/.well-known/oauth-protected-resource/beamlet/mcp`,
  the form a client derives from the MCP URL and tries first. The
  authorization server document answers at
  `/.well-known/oauth-authorization-server`. The contents are
  `Beamlet.OAuth`'s.
  """

  use Phoenix.Controller, formats: [:json]

  alias Beamlet.OAuth

  @doc "The protected resource metadata document."
  @spec protected_resource(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def protected_resource(conn, _params), do: json(conn, OAuth.protected_resource_metadata())

  @doc "The authorization server metadata document."
  @spec authorization_server(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authorization_server(conn, _params), do: json(conn, OAuth.authorization_server_metadata())
end
