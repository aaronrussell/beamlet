defmodule Beamlet.Routes do
  @moduledoc """
  The route table and the router derived from it.

  Rows (`Beamlet.Route`) in the `__routes` table of the agent database
  are the durable record of the URL surface agents build; the router
  that serves them, `Beamlet.DynamicRouter`, is a derived artifact:
  rendered from the rows, compiled through the code server's lane
  (`Beamlet.Code.compile_artifact/2`) and hot-swapped into the VM,
  never written to disk and never committed. It is rebuilt at boot,
  by a synchronous child of `Beamlet` right after the code server,
  and after every change to the table.

  The verbs here change the table and nothing else. Regeneration is
  the caller's to compose, which is what `Host.Router` does: insert,
  regenerate, and delete the row again when regeneration fails. A row
  whose target is missing, quarantined or of the wrong shape is left
  out at generation with a warning and answers 404; the row stays in
  the table for inspection. Boot regeneration never fails the boot:
  the worst case is the empty placeholder serving 404s with an error
  in the log.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  require Logger

  alias Beamlet.Config
  alias Beamlet.Route
  alias Beamlet.Routes.Generator

  @typedoc "Filters for `list/1`."
  @type filter :: {:path, String.t()} | {:verb, Route.verb()} | {:modules, [String.t()]}

  @doc "Inserts a route row. Does not regenerate the router."
  @spec create(map()) :: {:ok, Route.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Route{}
    |> Route.changeset(attrs)
    |> Host.Repo.insert()
  end

  @doc "Deletes a route row. Does not regenerate the router."
  @spec delete(Route.t()) :: :ok
  def delete(%Route{} = route) do
    Host.Repo.delete!(route)
    :ok
  end

  @doc """
  The route rows in id order, the order they were mounted, which is
  the order the router matches them in. Filters narrow the list:
  `path:` to one path, `verb:` to one verb, `modules:` to rows
  targeting any of the given module names in inspect form.
  """
  @spec list([filter()]) :: [Route.t()]
  def list(filters \\ []) do
    query = from(r in Route, order_by: r.id)

    filters
    |> Enum.reduce(query, fn
      {:path, path}, query -> where(query, [r], r.path == ^path)
      {:verb, verb}, query -> where(query, [r], r.verb == ^verb)
      {:modules, modules}, query -> where(query, [r], r.module in ^modules)
    end)
    |> Host.Repo.all()
  end

  @doc """
  Rebuilds the router from the table: rows whose targets cannot serve
  are left out with a warning each, the rest are rendered under the
  configured prefix and compiled in. On a compile failure the
  previous router keeps serving and the error is returned.
  """
  @spec regenerate() :: :ok | {:error, String.t()}
  def regenerate do
    {servable, broken} = Enum.split_with(list(), &servable?/1)
    Enum.each(broken, &log_broken/1)
    source = Generator.source(servable, Config.web()[:prefix])

    case Beamlet.Code.compile_artifact(source, "dynamic_router.ex") do
      {:ok, _modules} ->
        :ok

      {:error, message} ->
        Logger.error(
          "routes: the router failed to regenerate, the previous one keeps serving: #{message}"
        )

        {:error, message}
    end
  end

  @doc """
  Whether a route's target can serve it: loaded and a LiveView for a
  `:live_view` row; loaded, a Phoenix controller and exporting the
  action for a `:controller` row. `use Phoenix.Controller` leaves no
  marker like `__live__/0`, so the controller pipeline's `action/2`
  stands in, which a plain plug never defines.
  """
  @spec servable?(Route.t()) :: boolean()
  def servable?(%Route{kind: :live_view} = route) do
    target = Route.target(route)
    Code.ensure_loaded?(target) and function_exported?(target, :__live__, 0)
  end

  def servable?(%Route{kind: :controller} = route) do
    target = Route.target(route)

    Code.ensure_loaded?(target) and function_exported?(target, :action, 2) and
      function_exported?(target, Route.action_atom(route), 2)
  end

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :boot, []}}

  @doc """
  Boot regeneration, as a synchronous child: any failure is logged
  and the beamlet boots serving the placeholder. An empty table and
  an empty loaded router already agree, so that case compiles
  nothing, which is what keeps a test suite that boots a beamlet per
  test from paying a router compile each time.
  """
  @spec boot() :: :ignore
  def boot do
    unless list() == [] and Beamlet.DynamicRouter.__routes__() == [], do: regenerate()
    :ignore
  rescue
    exception ->
      Logger.error(
        "routes: boot regeneration failed, the routes are not served: " <>
          Exception.message(exception)
      )

      :ignore
  end

  defp log_broken(route) do
    Logger.warning(
      "routes: #{verb_word(route.verb)} #{route.path} is not served: #{route.module} " <>
        "is missing or does not serve a #{route.kind} route"
    )
  end

  defp verb_word(verb), do: verb |> Atom.to_string() |> String.upcase()
end
