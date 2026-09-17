defmodule Beamlet.TestRouter do
  @moduledoc """
  The host router of the suite: one route of the host's own, to prove
  host routes win by order, then the forward to `Beamlet.Router`.
  """

  use Phoenix.Router, helpers: false

  get "/host/ping", Beamlet.TestRouter.Ping, []

  forward "/", Beamlet.Router
end

defmodule Beamlet.TestRouter.Ping do
  @moduledoc false

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "pong")
end
