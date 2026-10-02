defmodule Beamlet.AssetsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  defp get(path), do: Beamlet.Assets.call(conn(:get, path), Beamlet.Assets.init([]))

  test "serves the modules the root layout imports, with their source maps" do
    for path <- [
          "/beamlet/assets/phoenix/phoenix.mjs",
          "/beamlet/assets/phoenix/phoenix.mjs.map",
          "/beamlet/assets/phoenix_live_view/phoenix_live_view.esm.js",
          "/beamlet/assets/phoenix_live_view/phoenix_live_view.esm.js.map"
        ] do
      conn = get(path)

      assert conn.status == 200, "#{path} answered #{conn.status}"
      assert byte_size(conn.resp_body) > 0
    end

    assert get_resp_header(get("/beamlet/assets/phoenix/phoenix.mjs"), "content-type") ==
             ["text/javascript"]
  end

  test "serves the stylesheet for the app" do
    conn = get("/beamlet/assets/app.css")

    assert conn.status == 200
    assert conn.resp_body =~ "tailwindcss"
    assert get_resp_header(conn, "content-type") == ["text/css"]
  end

  test "the other builds shipped beside them are not served" do
    assert File.exists?(Application.app_dir(:phoenix, "priv/static/phoenix.js"))

    for path <- [
          "/beamlet/assets/phoenix/phoenix.js",
          "/beamlet/assets/phoenix_live_view/phoenix_live_view.js"
        ] do
      conn = get(path)
      refute conn.halted
      assert conn.state == :unset
    end
  end
end
