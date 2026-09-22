defmodule Beamlet.AssetsTest do
  use Beamlet.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  setup do
    %{conn: build_conn()}
  end

  test "serves the modules the root layout imports, with their source maps", %{conn: conn} do
    for path <- [
          "/beamlet/assets/phoenix/phoenix.mjs",
          "/beamlet/assets/phoenix/phoenix.mjs.map",
          "/beamlet/assets/phoenix_live_view/phoenix_live_view.esm.js",
          "/beamlet/assets/phoenix_live_view/phoenix_live_view.esm.js.map"
        ] do
      conn = get(conn, path)

      assert conn.status == 200, "#{path} answered #{conn.status}"
      assert byte_size(conn.resp_body) > 0
    end

    assert conn |> get("/beamlet/assets/phoenix/phoenix.mjs") |> get_resp_header("content-type") ==
             ["text/javascript"]
  end

  test "serves the stylesheet for the beamlet's own pages", %{conn: conn} do
    conn = get(conn, "/beamlet/assets/beamlet.css")

    assert conn.status == 200
    assert conn.resp_body =~ "tailwindcss"
    assert get_resp_header(conn, "content-type") == ["text/css"]
  end

  test "the other builds shipped beside them are not reachable", %{conn: conn} do
    assert File.exists?(Application.app_dir(:phoenix, "priv/static/phoenix.js"))

    assert conn |> get("/beamlet/assets/phoenix/phoenix.js") |> response(404)
    assert conn |> get("/beamlet/assets/phoenix_live_view/phoenix_live_view.js") |> response(404)
  end
end
