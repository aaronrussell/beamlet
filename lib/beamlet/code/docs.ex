defmodule Beamlet.Code.Docs do
  @moduledoc false

  # The docs gate on a define buffer. Documentation is the discovery
  # surface: what an agent defines is found later through its docs,
  # so an undocumented module is an unfindable one and the gate is
  # enforced, not suggested. Checked in the AST before compilation.
  #
  # Every module needs a real @moduledoc; @moduledoc false is refused
  # since a hidden module cannot be discovered. Every public function
  # or macro needs a @doc; @doc false is accepted, since hiding a
  # helper is a documented decision. @spec is not required: specs do
  # not ride the docs chunk and a wrong one misinforms, so argument
  # and return shapes belong in the @doc prose. Clauses share their
  # function's @doc, tracked per name.
  #
  # Modules whose public functions are framework callbacks are exempt
  # from the per-function requirement, the moduledoc still required:
  # `use Host.Web, :live_view | :controller | :live_component` and the
  # Phoenix modules beneath them, since such a module is found through
  # the route table, not its function list; and `use Ecto.Migration`,
  # `Ecto.Type` and `Ecto.ParameterizedType`, whose functions Ecto
  # invokes. `use Ecto.Schema` keeps the gate: changeset/2 is the
  # module's own API and its @doc is where the fields get written
  # down. `use Host.Web, :html` keeps it too, since components are
  # discoverable functions. The match is syntactic, on the `use` line.

  @public_kinds [:def, :defmacro, :defdelegate]
  @private_kinds [:defp, :defmacrop]
  @framework_uses [
    [:Phoenix, :LiveView],
    [:Phoenix, :Controller],
    [:Phoenix, :LiveComponent],
    [:Ecto, :Migration],
    [:Ecto, :Type],
    [:Ecto, :ParameterizedType]
  ]
  @framework_roles [:live_view, :controller, :live_component]

  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(code) do
    code
    |> Code.string_to_quoted!()
    |> top_level_modules()
    |> Enum.flat_map(fn {module, body} -> check_module(module, body) end)
    |> case do
      [] -> :ok
      violations -> {:error, Enum.join(violations, "\n")}
    end
  rescue
    e in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, "line #{e.line}: #{e.description}"}
  end

  defp top_level_modules(ast) do
    ast
    |> block_forms()
    |> Enum.flat_map(fn
      {:defmodule, _meta, [{:__aliases__, _, parts}, [{:do, body} | _]]} ->
        if is_list(parts) and Enum.all?(parts, &is_atom/1),
          do: [{Module.concat(parts), body}],
          else: []

      _other ->
        []
    end)
  end

  defp block_forms({:__block__, _meta, forms}), do: forms
  defp block_forms(form), do: [form]

  defp check_module(module, body) do
    forms = block_forms(body)

    state = %{
      module: module,
      moduledoc: :missing,
      exempt: Enum.any?(forms, &framework_use?/1),
      pending_doc: false,
      documented: MapSet.new(),
      violations: []
    }

    state = Enum.reduce(forms, state, &form/2)
    violations = Enum.reverse(state.violations)

    case state.moduledoc do
      :present ->
        violations

      :missing ->
        [
          "#{inspect(module)} is missing @moduledoc — the moduledoc is how this " <>
            "module is discovered later; describe what it is for"
          | violations
        ]

      :hidden ->
        [
          "@moduledoc false hides #{inspect(module)} from discovery — write a real moduledoc"
          | violations
        ]
    end
  end

  defp form({:@, _meta, [{:moduledoc, _, [false]}]}, state), do: %{state | moduledoc: :hidden}
  defp form({:@, _meta, [{:moduledoc, _, [_value]}]}, state), do: %{state | moduledoc: :present}
  defp form({:@, _meta, [{:doc, _, [_value]}]}, state), do: %{state | pending_doc: true}

  defp form({kind, _meta, [head | _rest]}, state) when kind in @public_kinds do
    case function_name(head) do
      {:ok, name, arity} -> public_function(state, name, arity)
      :error -> state
    end
  end

  # A @doc attaches to whatever definition follows it, so one consumed
  # by a private function does not document the next public one.
  defp form({kind, _meta, _args}, state) when kind in @private_kinds do
    %{state | pending_doc: false}
  end

  defp form(_form, state), do: state

  defp framework_use?({:use, _meta, [{:__aliases__, _, [:Host, :Web]}, role]}),
    do: role in @framework_roles

  defp framework_use?({:use, _meta, [{:__aliases__, _, parts} | _opts]}),
    do: parts in @framework_uses

  defp framework_use?(_form), do: false

  defp public_function(%{pending_doc: true} = state, name, _arity) do
    %{state | pending_doc: false, documented: MapSet.put(state.documented, name)}
  end

  defp public_function(state, name, arity) do
    if state.exempt or MapSet.member?(state.documented, name) do
      state
    else
      violation =
        "#{inspect(state.module)}.#{name}/#{arity} is missing @doc — " <>
          "document every public function (argument and return shapes belong here)"

      %{state | violations: [violation | state.violations]}
    end
  end

  defp function_name({:when, _meta, [head | _guards]}), do: function_name(head)

  defp function_name({name, _meta, args}) when is_atom(name) do
    {:ok, name, if(is_list(args), do: length(args), else: 0)}
  end

  defp function_name(_head), do: :error
end
