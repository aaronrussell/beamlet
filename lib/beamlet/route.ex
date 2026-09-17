defmodule Beamlet.Route do
  @moduledoc """
  One row of the URL surface agents build: a path served by a module
  defined on the beamlet, through the router `Beamlet.Routes`
  generates from these rows.

  Two kinds. A `:live_view` row is an HTML page, served through the
  browser pipeline with a session and CSRF protection; a
  `:controller` row is an action for one HTTP verb, served through
  the API pipeline with neither, so external services can call it. A
  LiveView row stores `:get`, the verb it genuinely answers, so the
  unique index on verb and path collides a page with a controller GET
  at the same path while letting the other verbs share it.

  `module` is the target's name in inspect form, `"Todo.PageLive"`,
  and `action` names the controller action, or the live action on a
  page (`socket.assigns.live_action`), or nothing. The format
  validations are load-bearing rather than defensive: these fields
  are interpolated into router source when the router is generated.

  `principal` is the provenance of the row, the principal that
  mounted it, stored as JSON in the shape `Beamlet.Principal.to_map/1`
  gives and read back with `principal/1`.
  """

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
    |> cast(attrs, [:kind, :verb, :path, :module, :action])
    |> put_principal(principal)
    |> validate_required([:kind, :path, :module, :principal])
    |> validate_format(:path, @path_format)
    |> validate_format(:module, @module_format)
    |> validate_kind()
    |> unique_constraint(:path, name: :__routes_verb_path_index)
  end

  @doc "The target module as an atom."
  @spec target(t()) :: module()
  def target(%__MODULE__{module: module}), do: Module.concat([module])

  @doc "The controller or live action as an atom. Rows with an action only."
  @spec action_atom(t()) :: atom()
  def action_atom(%__MODULE__{action: action}) when is_binary(action),
    do: String.to_atom(action)

  @doc "The principal that mounted the route, decoded from the row."
  @spec principal(t()) :: {:ok, Principal.t()} | :error
  def principal(%__MODULE__{principal: map}), do: Principal.from_map(map)

  defp put_principal(changeset, %Principal{} = principal),
    do: put_change(changeset, :principal, Principal.to_map(principal))

  defp put_principal(changeset, _none), do: changeset

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
