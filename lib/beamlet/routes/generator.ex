defmodule Beamlet.Routes.Generator do
  @moduledoc false

  # Builds Beamlet.DynamicRouter, a real Phoenix router that
  # Beamlet.Routes.regenerate/0 compiles and hot-swaps, from route
  # rows as quoted form: a row's path goes in as a binary and its
  # module and action as atoms, so the router is built from data,
  # never from source text. Two convention pipelines: live_view rows get the browser
  # pipeline (session, CSRF protection, the root layout) and
  # controller rows the API pipeline (neither, so a webhook can call
  # them). No auth anywhere: every route is public. The prefix
  # becomes the scope path, "/" for the root; rows go in in the order
  # given, so an earlier row wins an overlapping match, as in a
  # hand-written router, each run of one kind in its own scope through
  # that kind's pipeline. __served__/0 lists the rows built in by key,
  # so what the router serves can be compared with the table.

  alias Beamlet.Route

  @router Beamlet.DynamicRouter

  @doc """
  The quoted `Beamlet.DynamicRouter` serving the rows under the
  prefix, ready to compile.
  """
  @spec quoted([Route.t()], String.t()) :: Macro.t()
  def quoted(routes, prefix) do
    scope_path = if prefix == "", do: "/", else: prefix
    scopes = routes |> Enum.chunk_by(& &1.kind) |> Enum.map(&scope(&1, scope_path))
    served = routes |> Enum.map(&key/1) |> Macro.escape()

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
          plug :put_root_layout, html: {Beamlet.Web.Layouts, :agent}
          plug :protect_from_forgery
          plug :put_secure_browser_headers
        end

        pipeline :api do
          plug :accepts, ["json"]
        end

        unquote_splicing(scopes)

        def __served__, do: unquote(served)
      end
    end
  end

  @doc false
  @spec key(Route.t()) :: tuple()
  def key(route), do: {route.kind, route.verb, route.path, route.module, route.action}

  defp scope([%Route{kind: :live_view} | _rest] = routes, scope_path) do
    quote do
      scope unquote(scope_path) do
        pipe_through :browser
        unquote_splicing(Enum.map(routes, &live_line/1))
      end
    end
  end

  defp scope(routes, scope_path) do
    quote do
      scope unquote(scope_path) do
        pipe_through :api
        unquote_splicing(Enum.map(routes, &controller_line/1))
      end
    end
  end

  defp live_line(%Route{action: nil} = route) do
    quote do: live(unquote(route.path), unquote(Route.target(route)))
  end

  # A live action names no function, so a loaded target need not hold
  # its atom and String.to_existing_atom/1 could refuse a route that
  # serves. Only rows with a defined LiveView target reach here.
  defp live_line(route) do
    quote do
      live(
        unquote(route.path),
        unquote(Route.target(route)),
        unquote(String.to_atom(route.action))
      )
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
