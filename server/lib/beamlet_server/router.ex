defmodule BeamletServer.Router do
  use Phoenix.Router, helpers: false

  forward "/", Beamlet.Router
end
