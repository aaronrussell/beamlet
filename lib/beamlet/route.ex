defmodule Beamlet.Route do
  @moduledoc false

  # One row of the URL surface agents build: a path served by a module
  # defined on the beamlet, through the router `Beamlet.Routes`
  # generates from these rows.
  #
  # Two kinds. A `:live_view` row is an HTML page, served through the
  # browser pipeline with a session and CSRF protection; a
  # `:controller` row is an action for one HTTP verb, served through
  # the API pipeline with neither, so external services can call it. A
  # LiveView row stores `:get`, the verb it genuinely answers, so the
  # unique index on verb and path collides a page with a controller GET
  # at the same path while letting the other verbs share it.
  #
  # `module` is the target's name in inspect form, `"Todo.PageLive"`,
  # and `action` names the controller action, or the live action on a
  # page (`socket.assigns.live_action`), or nothing. The formats, and
  # Plug's reading of the path, which refuses a glob anywhere but
  # last, are checked on insert and again at generation
  # (`load_changeset/1`), since agents can write the table with raw
  # SQL; a row failing them is left out of the router.
  #
  # `principal` is the provenance of the row, the principal that
  # mounted it, stored as JSON in the shape `Beamlet.Principal.to_map/1`
  # gives and read back with `principal/1`.

  use Ecto.Schema

  import Ecto.Changeset

  alias Beamlet.Principal

  schema "__routes" do
    field(:kind, Ecto.Enum, values: [:live_view, :controller])
    field(:verb, Ecto.Enum, values: [:get, :post, :put, :patch, :delete])
    field(:path, :string)
    field(:module, :string)
    field(:action, :string)
    field(:principal, :map)
    timestamps(updated_at: false, type: :utc_datetime)
  end

  @typedoc "An HTTP verb a route answers."
  @type verb :: :get | :post | :put | :patch | :delete

  @typedoc "A route row."
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          kind: :live_view | :controller,
          verb: verb(),
          path: String.t(),
          module: String.t(),
          action: String.t() | nil,
          principal: map(),
          inserted_at: DateTime.t() | nil
        }

  @path_format ~r{\A/[A-Za-z0-9_\-/:.*]*\z}
  @module_format ~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/
  @action_format ~r/\A[a-z_][a-z0-9_]*[?!]?\z/
  @fields [:kind, :verb, :path, :module, :action]

  @doc """
  The changeset for a new route. `attrs` carries the principal as a
  `Beamlet.Principal` under `:principal`; a `:live_view` row has its
  verb forced to `:get` and its action optional, a `:controller` row
  requires both.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(route, attrs) do
    {principal, attrs} = Map.pop(attrs, :principal)

    route
    |> cast(attrs, @fields)
    |> put_principal(principal)
    |> validate_required([:principal])
    |> validate_fields()
    |> unique_constraint(:path, name: :__routes_verb_path_index)
  end

  @doc """
  The changeset that revalidates a row read back from the table.

  Rows can be written with raw SQL, past `changeset/2`, so the
  router generator checks each one with the same rules before it
  serves it. The row's fields are cast onto a fresh struct, since
  format validations only check changes.
  """
  @spec load_changeset(t()) :: Ecto.Changeset.t()
  def load_changeset(%__MODULE__{} = route) do
    %__MODULE__{}
    |> cast(Map.from_struct(route), @fields)
    |> validate_fields()
  end

  @doc """
  The target module as an atom.

  Only an existing atom: rows can be written with raw SQL, and
  turning their strings into new atoms at every regeneration would
  fill the atom table. Raises `ArgumentError` when the atom does not
  exist, which means no such module was ever loaded.
  """
  @spec target(t()) :: module()
  def target(%__MODULE__{module: module}), do: String.to_existing_atom("Elixir." <> module)

  @doc """
  The controller action as an atom.

  An existing atom only, raising `ArgumentError` otherwise, as
  `target/1` does: an exported function's name exists as an atom
  once its module is loaded.
  """
  @spec action_atom(t()) :: atom()
  def action_atom(%__MODULE__{action: action}) when is_binary(action),
    do: String.to_existing_atom(action)

  @doc "The HTTP method for a verb as a request line writes it, e.g. `\"GET\"`."
  @spec method(verb()) :: String.t()
  def method(verb), do: verb |> Atom.to_string() |> String.upcase()

  @doc "The principal that mounted the route, decoded from the row."
  @spec principal(t()) :: {:ok, Principal.t()} | :error
  def principal(%__MODULE__{principal: map}), do: Principal.from_map(map)

  defp put_principal(changeset, %Principal{} = principal),
    do: put_change(changeset, :principal, Principal.to_map(principal))

  defp put_principal(changeset, _none), do: changeset

  defp validate_fields(changeset) do
    changeset
    |> validate_required([:kind, :path, :module])
    |> validate_format(:path, @path_format)
    |> validate_change(:path, &validate_routable/2)
    |> validate_format(:module, @module_format)
    |> validate_kind()
  end

  # Plug's own reading of the path, the one Phoenix compiles the
  # router with, so a path it refuses never reaches the build.
  defp validate_routable(:path, path) do
    Plug.Router.Utils.build_path_match(path)
    []
  rescue
    exception in Plug.Router.InvalidSpecError -> [path: Exception.message(exception)]
  end

  defp validate_kind(changeset) do
    case get_field(changeset, :kind) do
      :live_view ->
        changeset
        |> put_change(:verb, :get)
        |> validate_format(:action, @action_format)

      :controller ->
        changeset
        |> validate_required([:verb, :action])
        |> validate_format(:action, @action_format)

      nil ->
        changeset
    end
  end
end
