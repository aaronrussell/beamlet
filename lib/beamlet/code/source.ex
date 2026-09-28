defmodule Beamlet.Code.Source do
  @moduledoc false

  # Pure functions over a module's source text: the outline, a
  # function's block, a line range, and the function-level diff
  # between two versions. Everything is what the parser sees,
  # Code.string_to_quoted/2 with token metadata, and nothing is
  # compiled or evaluated, so it is safe on a quarantined module.
  #
  # The outline is every top-level form of the module, each with the
  # lines it spans, so the diff and select see the whole file; what
  # the outline shows is the renderer's choice, by kind. A function's
  # block is all its clauses plus the forms directly above the first
  # that document or annotate it: @doc, @spec, @impl, @deprecated,
  # and Phoenix's attr and slot. A type takes the @typedoc above it
  # and a callback its @doc, the same way. Any other form directly
  # above stays where it is, and comments are not forms and never
  # attach. Clauses of one name and arity that follow one another,
  # attachments between them included, are one block; the same name
  # and arity appearing again after another definition is scattered,
  # which define refuses and only a hand-edited quarantined file can
  # carry. The outline lists such a function twice, honestly, and
  # select refuses it.
  #
  # Kinds beyond the function kinds: :type for @type, @typep and
  # @opaque; :callback for @callback and @macrocallback; :doc for
  # @moduledoc and an orphaned attachment; :attribute for any other
  # @name value, a constant or a struct option; :other for everything
  # else, use, alias, defstruct, a nested module, any macro call.

  @function_kinds [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]
  @type_kinds [:type, :typep, :opaque]
  @callback_kinds [:callback, :macrocallback]
  @attribute_attachments [:doc, :spec, :impl, :deprecated, :typedoc]
  @call_attachments [:attr, :slot]
  @label_width 60

  @type kind ::
          :def
          | :defp
          | :defmacro
          | :defmacrop
          | :defguard
          | :defguardp
          | :defdelegate
          | :type
          | :callback
          | :doc
          | :attribute
          | :other

  @type item :: %{
          kind: kind(),
          name: atom() | nil,
          arity: arity() | nil,
          clauses: pos_integer() | nil,
          label: String.t(),
          range: Range.t(),
          text: String.t()
        }

  @type diff ::
          :unchanged
          | {:ok, %{removed: [item()], changed: [{item(), item()}], new: [item()]}}
          | {:error, :unparseable}

  @spec parse(String.t()) :: {:ok, Macro.t()} | {:error, {pos_integer(), String.t()}}
  def parse(source) when is_binary(source) do
    case Code.string_to_quoted(source, token_metadata: true, literal_encoder: &literal/2) do
      {:ok, ast} -> {:ok, ast}
      {:error, {meta, message, token}} -> {:error, {meta[:line] || 1, message <> token}}
    end
  end

  defp literal(literal, meta), do: {:ok, {:__block__, meta, [literal]}}

  @spec outline(String.t()) :: {:ok, [item()]} | {:error, {pos_integer(), String.t()}}
  def outline(source) when is_binary(source) do
    with {:ok, ast} <- parse(source) do
      lines = String.split(source, "\n")

      items =
        ast
        |> block_forms()
        |> Enum.flat_map(&module_forms/1)
        |> walk(lines)

      {:ok, items}
    end
  end

  @spec select(String.t(), atom(), arity()) ::
          {:ok, item()}
          | {:error, :not_found, [String.t()]}
          | {:error, :scattered}
          | {:error, {pos_integer(), String.t()}}
  def select(source, name, arity) when is_atom(name) and is_integer(arity) do
    with {:ok, items} <- outline(source) do
      functions = Enum.filter(items, &function?/1)

      case Enum.filter(functions, &(&1.name == name and &1.arity == arity)) do
        [item] -> {:ok, item}
        [] -> {:error, :not_found, Enum.map(functions, &fa/1)}
        _several -> {:error, :scattered}
      end
    end
  end

  @spec line_count(String.t()) :: non_neg_integer()
  def line_count(source) when is_binary(source) do
    source |> String.trim_trailing("\n") |> String.split("\n") |> length()
  end

  @spec lines(String.t(), Range.t()) :: String.t()
  def lines(source, first..last//1) when is_binary(source) and first >= 1 and last >= first do
    source
    |> String.split("\n")
    |> Enum.slice((first - 1)..(last - 1)//1)
    |> Enum.join("\n")
  end

  @spec diff(String.t(), String.t()) :: diff()
  def diff(old, new) when is_binary(old) and is_binary(new) do
    with false <- old == new,
         {:ok, old_items} <- outline(old),
         {:ok, new_items} <- outline(new) do
      old_functions = functions_by_key(old_items)
      new_functions = functions_by_key(new_items)

      removed = for {key, item} <- old_functions, not Map.has_key?(new_functions, key), do: item
      added = for {key, item} <- new_functions, not Map.has_key?(old_functions, key), do: item

      changed =
        for {key, item} <- new_functions,
            before = old_functions[key],
            before.text != item.text,
            do: {before, item}

      {:ok, %{removed: sort(removed), changed: sort(changed), new: sort(added)}}
    else
      true -> :unchanged
      {:error, _parse} -> {:error, :unparseable}
    end
  end

  @spec render_diff(diff()) :: [String.t()]
  def render_diff(:unchanged), do: ["  - unchanged"]

  def render_diff({:error, :unparseable}),
    do: ["  - previous source did not parse, so nothing to compare"]

  def render_diff({:ok, %{removed: [], changed: [], new: []}}), do: ["  - no function changes"]

  def render_diff({:ok, %{removed: removed, changed: changed, new: added}}) do
    [
      {"removed", Enum.map(removed, &fa/1)},
      {"changed", Enum.map(changed, &changed_fa/1)},
      {"new", Enum.map(added, &fa/1)}
    ]
    |> Enum.reject(fn {_verb, names} -> names == [] end)
    |> Enum.map(fn {verb, names} -> "  - #{verb} #{Enum.join(names, ", ")}" end)
  end

  @spec fa(item()) :: String.t()
  def fa(%{name: name, arity: arity}), do: "#{name}/#{arity}"

  defp changed_fa({%{clauses: before}, %{clauses: after_} = item}) when before != after_,
    do: "#{fa(item)} (#{before} to #{after_} clauses)"

  defp changed_fa({_before, item}), do: fa(item)

  # A scattered function in an old, quarantined source is one function
  # to the diff: its clauses summed and its blocks read together.
  defp functions_by_key(items) do
    items
    |> Enum.filter(&function?/1)
    |> Enum.group_by(&{&1.name, &1.arity})
    |> Map.new(fn
      {key, [item]} ->
        {key, item}

      {key, [first | _rest] = pieces} ->
        {key,
         %{
           first
           | clauses: pieces |> Enum.map(& &1.clauses) |> Enum.sum(),
             text: Enum.map_join(pieces, "\n", & &1.text)
         }}
    end)
  end

  defp sort(items), do: Enum.sort_by(items, &range_start/1)

  defp range_start({_before, item}), do: item.range.first
  defp range_start(item), do: item.range.first

  defp function?(%{name: name}), do: name != nil

  # ── The walk ──────────────────────────────────────────────────────

  defp module_forms({:defmodule, _meta, [_name, [{_do, body}]]}), do: block_forms(body)
  defp module_forms(_other), do: []

  defp block_forms({:__block__, _meta, forms}), do: forms
  defp block_forms(form), do: [form]

  # Forward over the forms with two things in hand: the function
  # block under construction and the attachments waiting for
  # something to attach to. A clause of the same function extends the
  # block and absorbs the attachments; any other function, type or
  # callback starts its own item from the first attachment; anything
  # else flushes both, the attachments as doc items of their own.
  defp walk(forms, lines) do
    state = %{items: [], current: nil, pending: []}

    forms
    |> Enum.reduce(state, fn form, state -> step(form, form_range(form), state) end)
    |> flush_current()
    |> flush_pending()
    |> Map.fetch!(:items)
    |> Enum.reverse()
    |> Enum.map(&with_text(&1, lines))
  end

  defp step(form, range, state) do
    case classify(form) do
      {:function, kind, name, arity} ->
        function(state, kind, name, arity, range)

      {:definer, kind, label} ->
        state = flush_current(state)
        first = state.pending |> Enum.map(& &1.first) |> Enum.min(fn -> range.first end)
        add(%{state | pending: []}, item(kind, first..range.last//1, label))

      :attachment ->
        %{state | pending: [range | state.pending]}

      {:other, kind} ->
        state |> flush_current() |> flush_pending() |> add(item(kind, range))
    end
  end

  defp function(
         %{current: %{name: name, arity: arity} = current} = state,
         _kind,
         name,
         arity,
         range
       ) do
    %{
      state
      | current: %{current | clauses: current.clauses + 1, range: current.range.first..range.last},
        pending: []
    }
  end

  defp function(state, kind, name, arity, range) do
    state = flush_current(state)
    first = state.pending |> Enum.map(& &1.first) |> Enum.min(fn -> range.first end)
    label = "#{kind} #{name}/#{arity}"

    current = %{
      item(kind, first..range.last//1, label)
      | name: name,
        arity: arity,
        clauses: 1
    }

    %{state | current: current, pending: []}
  end

  defp item(kind, range, label \\ nil) do
    %{kind: kind, name: nil, arity: nil, clauses: nil, range: range, label: label}
  end

  defp flush_current(%{current: nil} = state), do: state
  defp flush_current(%{current: current} = state), do: add(%{state | current: nil}, current)

  defp flush_pending(%{pending: pending} = state) do
    pending
    |> Enum.reverse()
    |> Enum.reduce(%{state | pending: []}, fn range, state -> add(state, item(:doc, range)) end)
  end

  defp add(state, item), do: %{state | items: [item | state.items]}

  defp with_text(item, lines) do
    text =
      lines |> Enum.slice((item.range.first - 1)..(item.range.last - 1)//1) |> Enum.join("\n")

    Map.merge(item, %{text: text, label: item.label || first_line(item.range, lines)})
  end

  defp first_line(range, lines) do
    line = lines |> Enum.at(range.first - 1) |> String.trim()

    if String.length(line) > @label_width,
      do: String.slice(line, 0, @label_width - 3) <> "...",
      else: line
  end

  defp classify({:@, _meta, [{name, _, [_value]}]}) when name in @attribute_attachments,
    do: :attachment

  defp classify({name, _meta, args}) when name in @call_attachments and is_list(args),
    do: :attachment

  defp classify({kind, _meta, [head | _rest]}) when kind in @function_kinds do
    case function_name(head) do
      {:ok, name, arity} -> {:function, kind, name, arity}
      :error -> {:other, :other}
    end
  end

  defp classify({:@, _meta, [{:moduledoc, _, [_value]}]}), do: {:other, :doc}
  defp classify({:@, _meta, [{:behaviour, _, [_value]}]}), do: {:other, :other}

  defp classify({:@, _meta, [{kind, _, [spec]}]}) when kind in @type_kinds do
    case spec do
      {:"::", _, [{name, _, _args}, _definition]} when is_atom(name) ->
        {:definer, :type, "@#{kind} #{name}"}

      _other ->
        {:other, :other}
    end
  end

  defp classify({:@, _meta, [{kind, _, [spec]}]}) when kind in @callback_kinds do
    case function_name(callback_head(spec)) do
      {:ok, name, arity} -> {:definer, :callback, "@#{kind} #{name}/#{arity}"}
      :error -> {:other, :other}
    end
  end

  defp classify({:@, _meta, [{name, _, [_value]}]}) when is_atom(name), do: {:other, :attribute}
  defp classify(_form), do: {:other, :other}

  defp callback_head({:when, _meta, [spec | _guards]}), do: callback_head(spec)
  defp callback_head({:"::", _meta, [head, _return]}), do: head
  defp callback_head(other), do: other

  defp function_name({:when, _meta, [head | _guards]}), do: function_name(head)

  defp function_name({name, _meta, args}) when is_atom(name) do
    {:ok, name, if(is_list(args), do: length(args), else: 0)}
  end

  defp function_name(_head), do: :error

  # A do-block ends at its `end`; a one-liner and a heredoc attribute
  # end where the parser says the expression does; the greatest line
  # in the subtree is the fallback for a form with neither.
  defp form_range({_name, meta, _args} = form) do
    first = meta[:line]

    last =
      get_in(meta, [:end, :line]) || get_in(meta, [:end_of_expression, :line]) || max_line(form)

    first..max(first, last)//1
  end

  defp max_line(form) do
    {_ast, max} =
      Macro.prewalk(form, 0, fn
        {_name, meta, _args} = node, max when is_list(meta) -> {node, max(max, meta[:line] || 0)}
        node, max -> {node, max}
      end)

    max
  end
end
