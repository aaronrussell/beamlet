defmodule Host.HTTPTest do
  use Beamlet.Case, async: false

  alias Beamlet.Eval

  defmodule Plugin do
    def attach(request) do
      send(self(), :plugin_attached)
      request
    end
  end

  @url "http://example.test/items"

  setup do
    Req.Test.stub(Host.HTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Req.Test.json(conn, %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        authorization: Plug.Conn.get_req_header(conn, "authorization"),
        body: body
      })
    end)

    :ok
  end

  describe "requests" do
    test "each verb sends its method, tuple and bang alike" do
      for {fun, method} <- [
            get: "GET",
            post: "POST",
            put: "PUT",
            patch: "PATCH",
            delete: "DELETE"
          ] do
        assert {:ok, %Req.Response{status: 200, body: %{"method" => ^method}}} =
                 apply(Host.HTTP, fun, [@url])

        assert %Req.Response{body: %{"method" => ^method}} =
                 apply(Host.HTTP, :"#{fun}!", [@url])
      end

      assert {:ok, %Req.Response{status: 200}} = Host.HTTP.head(@url)
      assert %Req.Response{status: 200} = Host.HTTP.head!(@url)
    end

    test "request takes the method from the options, as Req's does" do
      assert Host.HTTP.request!(url: @url, method: :options).body["method"] == "OPTIONS"
      assert {:ok, %{body: %{"method" => "GET"}}} = Host.HTTP.request(@url)
    end

    test "Req's options arrive as sent" do
      body =
        Host.HTTP.post!(@url, json: %{name: "beamlet"}, params: [page: 2], auth: {:bearer, "t"}).body

      assert body["body"] == ~s({"name":"beamlet"})
      assert body["query"] == "page=2"
      assert body["authorization"] == ["Bearer t"]
    end

    test "a base URL may be a function" do
      body = Host.HTTP.get!("/items", base_url: fn -> "http://example.test/api" end).body
      assert body["path"] == "/api/items"
    end

    test "a decoder may be a function" do
      decoded = Host.HTTP.get!(@url, decoders: [json: fn body -> {:ok, byte_size(body)} end])
      assert is_integer(decoded.body)
    end

    test "an error comes back as a tuple and raises from the bang" do
      Req.Test.stub(Host.HTTP, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Host.HTTP.get(@url, retry: false)

      assert_raise Req.TransportError, fn -> Host.HTTP.get!(@url, retry: false) end
    end

    test "an into function streams the body" do
      test = self()

      response =
        Host.HTTP.get!(@url,
          into: fn {:data, chunk}, acc ->
            send(test, {:chunk, chunk})
            {:cont, acc}
          end
        )

      assert_received {:chunk, chunk}
      assert chunk =~ ~s("method":"GET")
      assert response.status == 200
    end
  end

  describe "the outbound guard" do
    setup do
      on_exit(fn -> Application.delete_env(:beamlet, :http) end)
    end

    test "loopback, private and reserved hosts are refused before anything is sent" do
      for url <- [
            "http://localhost:4000/todos",
            "http://nas.internal.test/",
            "http://127.0.0.1/",
            "http://10.0.0.5/",
            "http://192.168.1.1/admin",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://2130706433/"
          ] do
        assert {:error, %Host.HTTP.BlockedError{reason: :reserved_address}} = blocked(url)
      end
    end

    test "the bang variant raises the error" do
      unreached()

      assert_raise Host.HTTP.BlockedError, fn -> Host.HTTP.get!("http://localhost/") end
    end

    test "the error says what was refused and why, without credentials" do
      assert {:error, error} = blocked("http://admin:secret@10.0.0.5/status")

      assert Exception.message(error) ==
               "Host.HTTP does not reach http://10.0.0.5/status: its host is loopback, " <>
                 "on a private network, link-local or another reserved address, not one " <>
                 "on the public internet"

      refute inspect(error) =~ "secret"
    end

    test "a host that does not resolve is refused in ReqSSRF's words" do
      assert {:error, %Host.HTTP.BlockedError{reason: :unresolvable_host} = error} =
               blocked("http://nowhere.invalid/")

      assert Exception.message(error) =~ "the host does not resolve"
    end

    test "a redirect to a private host is refused at the redirect, once" do
      test = self()

      Req.Test.stub(Host.HTTP, fn conn ->
        send(test, :requested)

        conn
        |> Plug.Conn.put_resp_header("location", "http://10.0.0.5/admin")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, %Host.HTTP.BlockedError{url: url, reason: :reserved_address}} =
               Host.HTTP.get(@url)

      assert URI.to_string(url) == "http://10.0.0.5/admin"
      assert_received :requested
      refute_received :requested
    end

    test "allowed names and addresses pass" do
      Application.put_env(:beamlet, :http, allow: ["NAS.internal.test", "192.168.1.0/24", "::1"])

      for url <- ["http://nas.internal.test/", "http://192.168.1.20:8123/", "http://[::1]/"] do
        assert {:ok, %Req.Response{status: 200}} = Host.HTTP.get(url)
      end
    end

    test "a name that resolves into an allowed block is still refused" do
      Application.put_env(:beamlet, :http, allow: ["10.0.0.0/8"])

      assert {:ok, %Req.Response{status: 200}} = Host.HTTP.get("http://10.0.0.5/")

      assert {:error, %Host.HTTP.BlockedError{reason: :reserved_address}} =
               blocked("http://nas.internal.test/")
    end

    test "a redirect from an allowed host to another private one is refused" do
      Application.put_env(:beamlet, :http, allow: ["nas.internal.test"])

      Req.Test.stub(Host.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://router.internal.test/")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, %Host.HTTP.BlockedError{reason: :reserved_address}} =
               Host.HTTP.get("http://nas.internal.test/")
    end
  end

  describe "refusals" do
    test "plug is refused before anything is sent, from tuple and bang alike" do
      options = [plug: {Plug.Static, at: "/", from: "/"}]

      assert refused(fn -> Host.HTTP.get("http://x/beamlet.db", options) end) =~
               "Host.HTTP does not accept :plug: requests go over the network"

      assert refused(fn -> Host.HTTP.get!("http://x/beamlet.db", options) end) =~
               "does not accept :plug"
    end

    test "the adapter and the connection settings are refused" do
      assert refused(fn -> Host.HTTP.get(@url, adapter: Req.Finch.Other) end) =~
               "does not accept :adapter"

      assert refused(fn -> Host.HTTP.get(@url, unix_socket: "/var/run/docker.sock") end) =~
               "does not accept :unix_socket"

      proxy = [proxy: {:http, "10.0.0.5", 3128, []}]

      assert refused(fn -> Host.HTTP.get(@url, connect_options: proxy) end) =~
               "does not accept :connect_options"

      assert refused(fn -> Host.HTTP.get(@url, finch: Beamlet.Finch) end) =~
               "does not accept :finch"

      assert refused(fn -> Host.HTTP.get(@url, finch_request: fn r, _, _, _ -> r end) end) =~
               "does not accept :finch_request"
    end

    test "the disk cache is refused" do
      assert refused(fn -> Host.HTTP.get(@url, cache: true, cache_dir: "/") end) =~
               "not cached to disk"
    end

    test "netrc credentials are refused" do
      assert refused(fn -> Host.HTTP.get(@url, auth: {:netrc, "/etc/passwd"}) end) =~
               "credentials are passed, not read from files"

      assert refused(fn -> Host.HTTP.get(@url, auth: :netrc) end) =~ "auth :netrc"
    end

    test "into :self is refused, pointing at a function" do
      assert refused(fn -> Host.HTTP.get(@url, into: :self) end) =~
               "does not accept :into :self: stream with a function"
    end

    test "plugins never run" do
      assert_raise ArgumentError, ~r/unknown option :plugins/, fn ->
        Host.HTTP.get(@url, plugins: [Plugin])
      end

      refute_received :plugin_attached
    end

    test "an option Req does not know is refused, the guard's switch among them" do
      assert refused(fn -> Host.HTTP.get(@url, ssrf_check: false) end) =~
               "unknown option :ssrf_check"
    end

    test "the request must be a URL or options" do
      assert refused(fn -> apply(Host.HTTP, :get, [:nope]) end) =~
               "Host.HTTP takes a URL or a keyword list of options, got: :nope"
    end
  end

  describe "from agent code" do
    setup %{token: token} do
      %{principal: principal(token)}
    end

    test "Host.HTTP makes the request", %{principal: principal} do
      assert {:ok, ~s(=> "GET")} =
               Eval.run(~s|Host.HTTP.get!("#{@url}").body["method"]|, principal)
    end

    test "a refused host comes back as the error", %{principal: principal} do
      code = ~S"""
      case Host.HTTP.get("http://localhost:4000/") do
        {:error, %Host.HTTP.BlockedError{reason: reason}} -> reason
      end
      """

      assert {:ok, "=> :reserved_address"} = Eval.run(code, principal)
    end

    test "Req is refused, pointing at Host.HTTP", %{principal: principal} do
      assert {:error, message} =
               Eval.run(
                 ~s|Req.get!("http://x/beamlet.db", plug: {Plug.Static, at: "/", from: "/"})|,
                 principal
               )

      assert message =~ "Req.get!/2"
      assert message =~ "not permitted by your policy"
      assert message =~ "HTTP requests are made with Host.HTTP"

      assert {:error, message} = Eval.run("Req.new()", principal)
      assert message =~ "Req.new/0"
    end

    test "Host.HTTP refuses the plug the review reproduced", %{principal: principal} do
      assert {:error, message} =
               Eval.run(
                 ~s|Host.HTTP.get!("http://x/beamlet.db", plug: {Plug.Static, at: "/", from: "/"})|,
                 principal
               )

      assert message =~ "Host.HTTP does not accept :plug"
    end
  end

  defp blocked(url) do
    unreached()
    Host.HTTP.get(url)
  end

  defp unreached do
    Req.Test.stub(Host.HTTP, fn _conn -> flunk("a blocked request reached the network") end)
  end

  defp refused(fun) do
    Req.Test.stub(Host.HTTP, fn _conn -> flunk("a refused request reached the network") end)
    assert_raise(ArgumentError, fun).message
  end
end
