defmodule Beamlet.OAuth.ClientsTest do
  use Beamlet.Case

  @moduletag :capture_log

  alias Beamlet.OAuth.Clients

  @client_id "https://chat.example/client.json"
  @redirect_uri "https://chat.example/callback"
  @document %{
    "client_id" => @client_id,
    "client_name" => "Chat",
    "redirect_uris" => [@redirect_uri, "http://localhost/callback"]
  }

  defp serve(document) do
    Req.Test.stub(Clients, fn conn -> Req.Test.json(conn, document) end)
  end

  describe "fetch/1" do
    test "fetches the document and keeps the client id and redirect URIs" do
      serve(@document)

      assert Clients.fetch(@client_id) ==
               {:ok,
                %{
                  client_id: @client_id,
                  redirect_uris: [@redirect_uri, "http://localhost/callback"]
                }}
    end

    test "serves a second fetch from the cache" do
      test = self()

      Req.Test.stub(Clients, fn conn ->
        send(test, :fetched)
        Req.Test.json(conn, @document)
      end)

      assert {:ok, _} = Clients.fetch(@client_id)
      assert {:ok, _} = Clients.fetch(@client_id)
      assert_received :fetched
      refute_received :fetched
    end

    test "a client id must be an https URL with a host and no fragment" do
      Req.Test.stub(Clients, fn _conn -> flunk("nothing should be fetched") end)

      for id <- ["http://chat.example/client.json", @client_id <> "#x", "chat.example", "", nil] do
        assert Clients.fetch(id) == {:error, :invalid_client_id}
      end
    end

    test "a host written as an address, or resolving to a private one, is blocked" do
      Req.Test.stub(Clients, fn _conn -> flunk("nothing should be fetched") end)

      assert Clients.fetch("https://10.0.0.5/client.json") == {:error, :blocked}
      assert Clients.fetch("https://[::1]/client.json") == {:error, :blocked}
      assert Clients.fetch("https://db.internal.test/client.json") == {:error, :blocked}
      assert Clients.fetch("https://localhost/client.json") == {:error, :blocked}
    end

    test "the document must name the client id it was fetched from and list redirect URIs" do
      serve(%{@document | "client_id" => "https://other.example/client.json"})
      assert Clients.fetch(@client_id) == {:error, :invalid_document}

      serve(Map.delete(@document, "redirect_uris"))
      assert Clients.fetch(@client_id) == {:error, :invalid_document}

      serve(%{@document | "redirect_uris" => []})
      assert Clients.fetch(@client_id) == {:error, :invalid_document}

      serve(%{@document | "redirect_uris" => [1]})
      assert Clients.fetch(@client_id) == {:error, :invalid_document}

      Req.Test.stub(Clients, fn conn -> Req.Test.text(conn, "not json") end)
      assert Clients.fetch(@client_id) == {:error, :invalid_document}
    end

    test "a status other than 200, or no answer, is unreachable" do
      Req.Test.stub(Clients, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end)

      assert Clients.fetch(@client_id) == {:error, :unreachable}

      Req.Test.stub(Clients, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert Clients.fetch(@client_id) == {:error, :unreachable}
    end

    test "a body over 64KB is too large" do
      Req.Test.stub(Clients, fn conn -> Req.Test.text(conn, String.duplicate("a", 70_000)) end)
      assert Clients.fetch(@client_id) == {:error, :too_large}
    end
  end

  describe "redirect_uri_allowed?/2" do
    setup do
      %{
        document: %{
          client_id: @client_id,
          redirect_uris: [@redirect_uri, "http://localhost/callback"]
        }
      }
    end

    test "a listed URI matches exactly", %{document: document} do
      assert Clients.redirect_uri_allowed?(document, @redirect_uri)
      refute Clients.redirect_uri_allowed?(document, @redirect_uri <> "/")
      refute Clients.redirect_uri_allowed?(document, @redirect_uri <> "?x=1")
      refute Clients.redirect_uri_allowed?(document, "https://chat.example:8443/callback")
      refute Clients.redirect_uri_allowed?(document, nil)
    end

    test "a listed loopback URI matches either loopback host on any port", %{document: document} do
      assert Clients.redirect_uri_allowed?(document, "http://localhost/callback")
      assert Clients.redirect_uri_allowed?(document, "http://localhost:51234/callback")
      assert Clients.redirect_uri_allowed?(document, "http://127.0.0.1/callback")
      assert Clients.redirect_uri_allowed?(document, "http://127.0.0.1:51234/callback")
      refute Clients.redirect_uri_allowed?(document, "http://localhost:51234/other")
      refute Clients.redirect_uri_allowed?(document, "https://localhost:51234/callback")
      refute Clients.redirect_uri_allowed?(document, "http://[::1]:51234/callback")
    end

    test "the loopback rule goes both ways" do
      document = %{client_id: @client_id, redirect_uris: ["http://127.0.0.1/callback"]}
      assert Clients.redirect_uri_allowed?(document, "http://localhost:4321/callback")
    end

    test "a listed http URI that is not loopback still matches exactly" do
      document = %{client_id: @client_id, redirect_uris: ["http://chat.example/callback"]}
      assert Clients.redirect_uri_allowed?(document, "http://chat.example/callback")
      refute Clients.redirect_uri_allowed?(document, "http://chat.example:8080/callback")
    end
  end

  test "loopback?/1" do
    assert Clients.loopback?("http://localhost:5555/callback")
    assert Clients.loopback?("http://127.0.0.1/callback")
    refute Clients.loopback?(@redirect_uri)
  end
end
