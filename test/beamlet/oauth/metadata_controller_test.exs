defmodule Beamlet.OAuth.MetadataControllerTest do
  use Beamlet.Case

  import Phoenix.ConnTest

  @protected_resource %{
    "resource" => "http://localhost:4000/beamlet/mcp",
    "authorization_servers" => ["http://localhost:4000"],
    "bearer_methods_supported" => ["header"]
  }

  @authorization_server %{
    "issuer" => "http://localhost:4000",
    "authorization_endpoint" => "http://localhost:4000/beamlet/authorize",
    "token_endpoint" => "http://localhost:4000/beamlet/token",
    "response_types_supported" => ["code"],
    "grant_types_supported" => ["authorization_code", "refresh_token"],
    "code_challenge_methods_supported" => ["S256"],
    "token_endpoint_auth_methods_supported" => ["none"],
    "client_id_metadata_document_supported" => true,
    "authorization_response_iss_parameter_supported" => true
  }

  test "serves the protected resource document bare and with the MCP path appended" do
    for path <- [
          "/.well-known/oauth-protected-resource",
          "/.well-known/oauth-protected-resource/beamlet/mcp"
        ] do
      assert build_conn() |> get(path) |> json_response(200) == @protected_resource
    end
  end

  test "serves the authorization server document" do
    assert build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200) ==
             @authorization_server
  end

  test "the URLs the plug and the documents share come from the endpoint" do
    assert Beamlet.OAuth.issuer() == "http://localhost:4000"
    assert Beamlet.OAuth.resource() == "http://localhost:4000/beamlet/mcp"

    assert Beamlet.OAuth.resource_metadata_url() ==
             "http://localhost:4000/.well-known/oauth-protected-resource"
  end
end
