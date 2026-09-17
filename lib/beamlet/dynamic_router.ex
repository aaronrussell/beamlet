defmodule Beamlet.DynamicRouter do
  @moduledoc false

  # The router that serves the routes agents mount, in its
  # pre-generation state: empty, so everything under Beamlet.Router's
  # forward answers 404. It exists so that forward compiles against a
  # module that is there. At boot and after every change to the route
  # table, Beamlet.Routes.regenerate/0 renders the table into a new
  # module under this name and hot-swaps it in the VM; that version
  # is a derived artifact, never on disk, always rebuildable.

  use Phoenix.Router, helpers: false
end
