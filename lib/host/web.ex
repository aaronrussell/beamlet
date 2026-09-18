defmodule Host.Web do
  @moduledoc ~S'''
  The `use` line for a module on your beamlet's web surface.

  One line brings in the framework for the module's role, plus
  `Phoenix.HTML`, the `JS` alias and the `~p` sigil for paths in
  templates:

      defmodule Todo.PageLive do
        use Host.Web, :live_view

        def mount(_params, _session, socket) do
          {:ok, assign(socket, todos: Todo.List.all())}
        end

        def render(assigns) do
          ~H"""
          <ul :for={todo <- @todos}><li>{todo.name}</li></ul>
          <.link navigate={~p"/todos/new"}>Add one</.link>
          """
        end
      end

  `:live_view` for an HTML page, mounted with `Host.Router.live/2`;
  `:controller` for JSON API and webhook actions, mounted with the
  `Host.Router` function named after the HTTP verb, JSON-only with
  no session or CSRF; `:live_component` for a stateful component a
  page renders with `<.live_component>`; `:html` for a module of
  shared function components.

  A template is a `~H` sigil in `render/1`; `~p` is for the paths
  inside it, never the template itself. `<.link navigate={~p"..."}>`
  or `<.link patch={...}>` keeps navigation on the LiveView socket
  where a plain `<a href>` reloads the page. Pages render inside
  your beamlet's layout with Tailwind utility classes available; no
  stylesheet or asset setup is needed. For live updates, broadcast
  from the action that receives the change with `Host.PubSub` and
  subscribe in the LiveView's `mount/3`.
  '''

  @doc false
  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      unquote(helpers())
    end
  end

  @doc false
  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(helpers())
    end
  end

  @doc false
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(helpers())
    end
  end

  @doc false
  def html do
    quote do
      use Phoenix.Component

      unquote(helpers())
    end
  end

  defp helpers do
    quote do
      import Phoenix.HTML
      import Host.Router, only: [sigil_p: 2]

      alias Phoenix.LiveView.JS
    end
  end

  @doc """
  `use Host.Web, :live_view | :controller | :live_component | :html`,
  see the module documentation for what each brings in.
  """
  defmacro __using__(which) when which in [:controller, :live_view, :live_component, :html] do
    apply(__MODULE__, which, [])
  end

  defmacro __using__(other) do
    raise ArgumentError,
          "use Host.Web takes :live_view, :controller, :live_component or :html — " <>
            "got: #{inspect(other)}"
  end
end
