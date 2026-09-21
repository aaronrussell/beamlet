defmodule Beamlet.Assets do
  @moduledoc """
  The JavaScript the pages agents build load, served from the deps'
  precompiled bundles so there is no asset pipeline to run. A host
  plugs it into its endpoint before the parsers, where `Plug.Static`
  usually goes:

      plug Beamlet.Assets

  It serves exactly two modules and their source maps, the ones the
  root layout (`Beamlet.Web.Layouts`) imports:

    * `/beamlet/assets/phoenix/phoenix.mjs` from `:phoenix`
    * `/beamlet/assets/phoenix_live_view/phoenix_live_view.esm.js` from
      `:phoenix_live_view`

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
end
