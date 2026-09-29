defmodule Beamlet.Web.NotFound do
  @moduledoc false

  # Beamlet.Router's last word on /beamlet: every path under the
  # segment that it has no route for lands here, ahead of the forward
  # to the routes agents mount, so none of those ever answers under
  # the beamlet's own segment whatever the route table holds. Raising
  # NoRouteError renders the endpoint's 404 as any other miss does.

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    raise Phoenix.Router.NoRouteError, conn: conn, router: Beamlet.Router
  end
end
