defmodule Beamlet.Assets do
  @moduledoc """
  The files the beamlet's pages load, served under `/beamlet/assets`.
  A host plugs it into its endpoint before the parsers, where
  `Plug.Static` usually goes:

      plug Beamlet.Assets

  It serves the LiveView JavaScript from the deps' precompiled
  bundles, so there is no JavaScript build to run, and the stylesheet
  for the beamlet's own pages from the package's `priv/static`, built
  from `assets/css/beamlet.css` with `mix assets.build` and shipped
  built. The root layouts (`Beamlet.Web.Layouts`) reference exactly
  these:

    * `/beamlet/assets/phoenix/phoenix.mjs` from `:phoenix`
    * `/beamlet/assets/phoenix_live_view/phoenix_live_view.esm.js` from
      `:phoenix_live_view`
    * `/beamlet/assets/beamlet.css` from `:beamlet`

  Nothing else under those directories is reachable; the other builds
  of the same bundles answer 404. `/beamlet/assets` is one of the paths a
  beamlet reserves for itself (`Beamlet.Router`), so an agent cannot
  mount a route under it.
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
    only: ~w(beamlet.css)
end
