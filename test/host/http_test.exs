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
  end

  describe "the functions Req hands the request to" do
    test "an into function streams the body and sees no steps" do
      test = self()

      response =
        Host.HTTP.get!(@url,
          into: fn {:data, chunk}, {request, response} ->
            send(test, {:chunk, chunk, steps(request)})
            {:cont, {request, response}}
          end
        )

      assert_received {:chunk, chunk, {[], [], []}}
      assert chunk =~ ~s("method":"GET")
      assert response.status == 200
    end

    test "a retry function sees no steps" do
      test = self()
      Req.Test.stub(Host.HTTP, &Plug.Conn.send_resp(&1, 503, "down"))

      retry = fn request, _outcome ->
        send(test, {:retry, steps(request)})
        false
      end

      assert Host.HTTP.get!(@url, retry: retry).status == 503
      assert_received {:retry, {[], [], []}}
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

      assert refused(fn -> Host.HTTP.get(@url, connect_options: [timeout: 1]) end) =~
               "does not accept :connect_options"

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

    test "{mod, fun, args} values are refused" do
      mfa = {System, :get_env, ["HOME"]}

      for key <- [:base_url, :auth, :aws_sigv4] do
        assert refused(fn -> Host.HTTP.get(@url, [{key, mfa}]) end) =~
                 ":#{key} as {mod, fun, args}"
      end
    end

    test "a module decoder is refused" do
      assert refused(fn -> Host.HTTP.get(@url, decoders: [json: Jason]) end) =~
               "decoder {:json, Jason}"
    end

    test "into must be a function" do
      assert refused(fn -> Host.HTTP.get(@url, into: :self) end) =~ ":into :self"
      assert refused(fn -> Host.HTTP.get(@url, into: []) end) =~ ":into []"
    end

    test "bodies streamed from files are refused" do
      stream = File.stream!("mix.exs")

      assert refused(fn -> Host.HTTP.post(@url, body: stream) end) =~
               ":body streamed from a file"

      assert refused(fn ->
               Host.HTTP.post(@url, form_multipart: [file: {stream, filename: "mix.exs"}])
             end) =~ ":form_multipart streamed from a file"
    end

    test "plugins never run" do
      assert_raise ArgumentError, ~r/unknown option :plugins/, fn ->
        Host.HTTP.get(@url, plugins: [Plugin])
      end

      refute_received :plugin_attached
    end

    test "renamed options name the current one" do
      assert refused(fn -> Host.HTTP.get(@url, follow_redirects: false) end) =~
               "it is now :redirect"
    end

    test "a value Req does not take for a checked option is refused" do
      assert refused(fn -> Host.HTTP.get(@url, retry: :always) end) =~ ":retry :always"
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

  defp refused(fun) do
    Req.Test.stub(Host.HTTP, fn _conn -> flunk("a refused request reached the network") end)
    assert_raise(ArgumentError, fun).message
  end

  defp steps(request), do: {request.request_steps, request.response_steps, request.error_steps}
end
