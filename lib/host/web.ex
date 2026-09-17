defmodule Host.Web do
  @moduledoc """
  The entry point for modules on your beamlet's web surface. One
  `use` line brings in the right framework for the module's role,
  plus the `~p` sigil for paths in templates:

      defmodule Todo.PageLive do
        use Host.Web, :live_view
        ...
      end

  `:live_view` for an HTML page (mounted with `Host.Router.live/2`);
  `:controller` for JSON API and webhook actions (mounted with the
  `Host.Router` function named after the HTTP verb, JSON-only, no
  CSRF); `:live_component` for a stateful component a page renders
  with `<.live_component>`; `:html` for a module of shared function
  components.
  """

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
