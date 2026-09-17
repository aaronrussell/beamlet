defmodule Beamlet.RouteFixtures do
  @moduledoc """
  Compile-time targets for route tests: a LiveView and a controller
  the generated router can serve without a define. Every test boots a
  beamlet whose boot child regenerates the router from a table the
  sandbox has emptied, so no reset between tests is needed.
  """

  defmodule HelloLive do
    @moduledoc false
    use Phoenix.LiveView

    @impl true
    def mount(params, _session, socket) do
      {:ok, assign(socket, id: params["id"])}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div id="hello-live">hello from HelloLive, id={@id}, action {inspect(@live_action)}</div>
      """
    end
  end

  defmodule EchoController do
    @moduledoc false
    use Phoenix.Controller, formats: [:json]

    import Plug.Conn

    def show(conn, params), do: json(conn, %{echo: "show", params: params})

    def create(conn, params), do: json(conn, %{echo: "create", params: params})

    def plain(conn, _params), do: text(conn, "plain")

    def crash(_conn, _params), do: raise("boom")

    def whoami(conn, _params) do
      principal = Beamlet.Principal.current()
      json(conn, %{principal: principal && principal.user_name})
    end
  end
end
