defmodule Beamlet.RouteFixtures do
  @moduledoc """
  Targets for route tests: a LiveView and a controller, defined
  through the code server under a namespace unique to the test, since
  only modules defined with `define` serve. `define!/1` returns their
  names in inspect form, the form a route row stores.
  """

  import Beamlet.Case

  @spec define!(Beamlet.Principal.t()) :: %{hello: String.t(), echo: String.t()}
  def define!(principal) do
    ns = unique_namespace()
    purge_on_exit([Module.concat([ns, "HelloLive"]), Module.concat([ns, "EchoController"])])
    {:ok, _summary} = Beamlet.Code.define([entry(hello(ns)), entry(echo(ns))], principal)
    %{hello: "#{ns}.HelloLive", echo: "#{ns}.EchoController"}
  end

  defp hello(ns) do
    """
    defmodule #{ns}.HelloLive do
      use Host.Web, :live_view

      def mount(params, _session, socket) do
        {:ok, assign(socket, id: params["id"])}
      end

      def render(assigns) do
        ~H\"\"\"
        <div id="hello-live">hello from HelloLive, id={@id}, action {inspect(@live_action)}</div>
        \"\"\"
      end
    end
    """
  end

  # whoami answers whether the request acts as someone: print_policy
  # needs a principal and raises without one. session writes its query
  # params into the endpoint's session and answers with what it holds.
  defp echo(ns) do
    """
    defmodule #{ns}.EchoController do
      use Host.Web, :controller

      def show(conn, params), do: json(conn, %{echo: "show", params: params})

      def create(conn, params), do: json(conn, %{echo: "create", params: params})

      def plain(conn, _params), do: text(conn, "plain")

      def crash(_conn, _params), do: raise("boom")

      def whoami(conn, _params) do
        acting =
          try do
            Host.Code.print_policy()
            true
          rescue
            RuntimeError -> false
          end

        json(conn, %{acting: acting})
      end

      def session(conn, params) do
        conn = Enum.reduce(params, fetch_session(conn), fn {k, v}, conn -> put_session(conn, k, v) end)
        json(conn, get_session(conn))
      end
    end
    """
  end
end
