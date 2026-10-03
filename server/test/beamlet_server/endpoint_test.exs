defmodule BeamletServer.EndpointTest do
  # The application is the server as it ships: one beamlet under the
  # real endpoint and router, so the log level these tests raise is
  # the whole VM's.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint BeamletServer.Endpoint

  test "serves the beamlet through the real plug list and forward" do
    assert build_conn() |> get("/beamlet/login") |> html_response(200) =~ "Sign in"

    assert %{"error" => "unsupported_grant_type"} =
             build_conn() |> post("/beamlet/token") |> json_response(400)

    conn = build_conn() |> post("/beamlet/mcp")
    assert conn.status == 401
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ "Bearer"
  end

  describe "the request log" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "keeps the sign-in's password out" do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          post(build_conn(), "/beamlet/login",
            user: %{email: "owner@example.com", password: "hunter2-secret"}
          )
        end)

      assert log =~ ~s("password" => "[FILTERED]")
      refute log =~ "hunter2-secret"
    end

    test "keeps the token endpoint's secrets out" do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          post(build_conn(), "/beamlet/token",
            grant_type: "authorization_code",
            code: "code-secret",
            code_verifier: "verifier-secret"
          )

          post(build_conn(), "/beamlet/token",
            grant_type: "refresh_token",
            refresh_token: "refresh-secret"
          )
        end)

      assert log =~ ~s("code" => "[FILTERED]")
      for secret <- ~w(code-secret verifier-secret refresh-secret), do: refute(log =~ secret)
    end
  end
end
