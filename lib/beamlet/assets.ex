defmodule Beamlet.Assets do
  @moduledoc """
  Serves the files the beamlet's pages load, under `/beamlet/assets`.

  Plug it into your endpoint, before the parsers:

      plug Beamlet.Assets

  There is nothing to build. It serves the LiveView JavaScript from
  the bundles the Phoenix packages ship, and the beamlet's own
  stylesheet. Those three files are all it serves, and any other path
  under `/beamlet/assets` answers 404.
  """

  use Plug.Builder

  plug Plug.Static,
    at: "/beamlet/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.mjs phoenix.mjs.map)

  plug Plug.Static,
    at: "/beamlet/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.esm.js phoenix_live_view.esm.js.map)

  plug Plug.Static,
    at: "/beamlet/assets",
    from: {:beamlet, "priv/static"},
    only: ~w(app.css)
end
