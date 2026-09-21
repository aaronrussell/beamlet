defmodule Beamlet.Routes.Generator do
  @moduledoc false

  # Renders route rows into the source of Beamlet.DynamicRouter, a
  # real Phoenix router that Beamlet.Routes.regenerate/0 compiles and
  # hot-swaps. Two convention pipelines: live_view rows get the
  # browser pipeline (session, CSRF protection, the root layout) and
  # controller rows the API pipeline (neither, so a webhook can call
  # them). No auth anywhere: every route is public. The prefix
  # becomes the scope path, "/" for the root; rows render in the
  # order given, so an earlier row wins an overlapping match, as in
  # a hand-written router.

  alias Beamlet.Route

  @router Beamlet.DynamicRouter

  @spec source([Route.t()], String.t()) :: String.t()
  def source(routes, prefix) do
    {live_views, controllers} = Enum.split_with(routes, &(&1.kind == :live_view))
    scope_path = if prefix == "", do: "/", else: prefix

    """
    defmodule #{inspect(@router)} do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug :fetch_live_flash
        plug :put_root_layout, html: {Beamlet.Web.Layouts, :root}
        plug :protect_from_forgery
        plug :put_secure_browser_headers
      end

      pipeline :api do
        plug :accepts, ["json"]
      end

      scope #{inspect(scope_path)} do
        pipe_through :browser

    #{Enum.map_join(live_views, "\n", &live_line/1)}
      end

      scope #{inspect(scope_path)} do
        pipe_through :api

    #{Enum.map_join(controllers, "\n", &controller_line/1)}
      end
    end
    """
  end

  defp live_line(%Route{action: nil} = route) do
    ~s(    live "#{route.path}", #{route.module})
  end

  defp live_line(route) do
    ~s(    live "#{route.path}", #{route.module}, :#{route.action})
  end

  defp controller_line(route) do
    ~s(    #{route.verb} "#{route.path}", #{route.module}, :#{route.action})
  end
end
