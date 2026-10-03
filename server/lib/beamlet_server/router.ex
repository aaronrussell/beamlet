defmodule BeamletServer.Router do
  @moduledoc false

  # The server serves nothing of its own: every path goes to the
  # beamlet, whose router answers 404 for what nothing mounts.

  use Phoenix.Router, helpers: false

  forward "/", Beamlet.Router
end
