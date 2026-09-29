defmodule Beamlet.Routes.Generator do
  @moduledoc false

  # Builds Beamlet.DynamicRouter, a real Phoenix router that
  # Beamlet.Routes.regenerate/0 compiles and hot-swaps, from route
  # rows as quoted form: a row's path goes in as a binary and its
  # module and action as atoms, so nothing a row holds can become
  # code. Two convention pipelines: live_view rows get the browser
  # pipeline (session, CSRF protection, the root layout) and
  # controller rows the API pipeline (neither, so a webhook can call
  # them). No auth anywhere: every route is public. The prefix
  # becomes the scope path, "/" for the root; rows go in in the order
  # given, so an earlier row wins an overlapping match, as in a
  # hand-written router.

  alias Beamlet.Route

  @router Beamlet.DynamicRouter

  @spec quoted([Route.t()], String.t()) :: Macro.t()
  def quoted(routes, prefix) do
    {live_views, controllers} = Enum.split_with(routes, &(&1.kind == :live_view))
    scope_path = if prefix == "", do: "/", else: prefix
    live_lines = Enum.map(live_views, &live_line/1)
    controller_lines = Enum.map(controllers, &controller_line/1)

    quote do
      defmodule unquote(@router) do
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

        scope unquote(scope_path) do
          pipe_through :browser
          unquote_splicing(live_lines)
        end

        scope unquote(scope_path) do
          pipe_through :api
          unquote_splicing(controller_lines)
        end
      end
    end
  end

  defp live_line(%Route{action: nil} = route) do
    quote do: live(unquote(route.path), unquote(Route.target(route)))
  end

  defp live_line(route) do
    quote do
      live(unquote(route.path), unquote(Route.target(route)), unquote(Route.action_atom(route)))
    end
  end

  defp controller_line(route) do
    quote do
      unquote(route.verb)(
        unquote(route.path),
        unquote(Route.target(route)),
        unquote(Route.action_atom(route))
      )
    end
  end
end
