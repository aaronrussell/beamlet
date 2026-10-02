defmodule Beamlet.Routes do
  @moduledoc """
  The route table and the router derived from it.

  Rows (`Beamlet.Route`) in the `__routes` table of the agent database
  are the durable record of the URL surface agents build; the router
  that serves them, `Beamlet.DynamicRouter`, is a derived artifact:
  built from the rows as quoted form and compiled, both inside the
  code server's lane (`Beamlet.Code.compile_artifact/2`), then
  hot-swapped into the VM, never written to disk and never
  committed. Reading the rows in the lane is what keeps two
  regenerations racing from landing an older table over a newer
  one. It is rebuilt at boot, by a synchronous child of `Beamlet`
  right after the code server, and after every change to the table.

  `create`, `delete` and `list` change or read the table and nothing
  else. Regeneration is the caller's to compose, which is what
  `Host.Router` does: insert, regenerate, and delete the row again
  when regeneration fails. A row whose target is not a module defined
  with `define`, is missing, quarantined or of the wrong shape is
  left out at generation with a warning and answers 404; the row
  stays in the table for inspection. A define can repair a target or
  break one without touching the table, so `Beamlet.Define` and
  `Beamlet.Patch` call `refresh/0` after theirs, and redefining the
  module brings its routes back. A row that fails `Beamlet.Route`'s
  validations could only have been written with raw SQL and nothing
  can make it valid again, so regeneration deletes it with a warning
  recording the row. Boot regeneration never fails the boot: the worst case is
  the empty placeholder serving 404s with an error in the log.
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
  Rebuilds the router from the table: malformed rows are deleted and
  rows whose targets cannot serve are left out, with a warning each,
  and the rest are built under the configured prefix and compiled
  in. The table is read inside the code server's lane, so the router
  that lands is the table as it stands when the compile runs. On a
  failure the previous router keeps serving and the error is
  returned.
  """
  @spec regenerate() :: :ok | {:error, String.t()}
  def regenerate do
    case Beamlet.Code.compile_artifact(&render/0, "dynamic_router.ex") do
      {:ok, _modules} ->
        :ok

      {:error, message} ->
        Logger.error(
          "routes: the router failed to regenerate, the previous one keeps serving: #{message}"
        )

        {:error, message}
    end
  end

  # Runs inside the code server's lane, so nothing here may call it:
  # servable?/1 reads the defined set from its table.
  defp render do
    {rows, malformed} = Enum.split_with(list(), &Route.load_changeset(&1).valid?)
    Enum.each(malformed, &prune/1)
    {servable, broken} = Enum.split_with(rows, &servable?/1)
    Enum.each(broken, &log_broken/1)
    Generator.quoted(servable, Config.web()[:prefix])
  end

  @doc """
  Rebuilds the router when it disagrees with the table: a row that
  can serve is missing from it, or a row it serves no longer can.
  Redefining a routed module that stays servable needs no rebuild,
  since the router names the module and the new version serves, so
  most defines compile nothing here.

  On a failure the previous router keeps serving, and the error is a
  warning for the summary of the define that called it, since the
  define stands.
  """
  @spec refresh() :: :ok | {:error, String.t()}
  def refresh do
    with false <- Enum.all?(list(), &(servable?(&1) == served?(&1))),
         {:error, message} <- regenerate() do
      {:error, refresh_warning(message)}
    else
      _ok -> :ok
    end
  rescue
    exception -> {:error, refresh_warning(Exception.message(exception))}
  end

  defp refresh_warning(message) do
    "Warning: the router failed to rebuild, so your routes serve as they did before this " <>
      "change: #{message}. Host.Router.print_routes() shows which are served."
  end

  @doc """
  Whether the router in the VM serves this row as it stands. False
  for a row the last regeneration left out, and for one changed or
  added since.
  """
  @spec served?(Route.t()) :: boolean()
  def served?(route), do: Generator.key(route) in Beamlet.DynamicRouter.__served__()

  @doc """
  Whether a route can serve: the row passes `Beamlet.Route`'s
  validations, and its target is a module defined with `define` that
  is loaded and a LiveView for a `:live_view` row, or a Phoenix
  controller exporting the action for a `:controller` row.

  The row is checked first because agents can write the table with
  raw SQL, and only a well-formed row is turned into atoms.
  `use Phoenix.Controller` leaves no marker like `__live__/0`, so the
  controller pipeline's `action/2` stands in, which a plain plug
  never defines.
  """
  @spec servable?(Route.t()) :: boolean()
  def servable?(route), do: well_formed?(route) and target_serves?(route)

  defp well_formed?(route), do: Route.load_changeset(route).valid?

  # A name with no atom was never loaded, so it cannot serve.
  defp target_serves?(%Route{kind: :live_view} = route) do
    target = Route.target(route)

    target in Beamlet.Code.defined() and Code.ensure_loaded?(target) and
      function_exported?(target, :__live__, 0)
  rescue
    ArgumentError -> false
  end

  defp target_serves?(%Route{kind: :controller} = route) do
    target = Route.target(route)

    target in Beamlet.Code.defined() and Code.ensure_loaded?(target) and
      function_exported?(target, :action, 2) and
      function_exported?(target, Route.action_atom(route), 2)
  rescue
    ArgumentError -> false
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

  # An unmount can delete the row between the list and the prune,
  # hence allow_stale.
  defp prune(route) do
    Host.Repo.delete!(route, allow_stale: true)
    fields = [:id, :kind, :verb, :path, :module, :action, :principal, :inserted_at]
    Logger.warning("routes: deleted a malformed row: #{inspect(Map.take(route, fields))}")
  end

  defp log_broken(route) do
    Logger.warning(
      "routes: #{Route.method(route.verb)} #{route.path} is not served: #{route.module} is not " <>
        "a module defined with define, or does not serve a #{route.kind} route"
    )
  end
end
