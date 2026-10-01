defmodule Beamlet.Scanner do
  @moduledoc """
  The scan every piece of submitted code passes before it runs or
  compiles: the one place a policy's rules and grants are enforced.

  The scanner walks the unexpanded AST and refuses, with teaching
  errors, what the policy does not admit. Grants decide names: every
  module and function the code reaches for must be granted, aliases
  are expanded first so `alias File, as: Storage` launders nothing,
  and a module may name itself. Rules decide shape: call targets must
  be literal modules unless the policy allows dynamic dispatch, a
  module may not define macros unless the policy allows them, `eval`
  code may not define modules, and a `define` entry is its one
  `defmodule` and nothing beside it.
  The targets of `alias`, `import`, `require` and `use`, and the
  data-position targets the compiler expands (`defdelegate to:`, the
  compile hooks, `@compile`) stay literal under any policy, and
  `@compile` may name no parse or core transform. `@derive` is
  refused, as `defimpl` is: protocols are consolidated at build, so
  an implementation added at runtime is never dispatched to. Every
  violation is collected and reported together, each with its
  locator and the offending line quoted beneath it.

  Struct literals are not checked against the grants. A struct is a
  map with a `__struct__` key, which `struct/2` or a plain map
  literal builds under any name, so refusing `%File.Stream{}` steers
  nothing; and a macro-generated module, an inline embedded schema,
  is named in its parent's own source before it exists.

  This is an anti-accident guardrail, not a security boundary. The
  approximations are deliberate: alias and import tracking is
  file-global in source order, macros of granted modules expand after
  the scan and unscanned, and a no-parens dot on a variable
  (`user.name`) is read as map field access and passes.
  """

  alias Beamlet.Policy
  alias Beamlet.Policy.Signage

  @eval_defmodule_error "eval evaluates expressions — module definitions are not permitted"
  @define_hint "; add a module to your beamlet with the define tool"
  @no_define_hint ", and your policy grants no define tool, so modules cannot be added with " <>
                    "this token; run the code here instead"
  @expression_error "define declares modules — run expressions with eval"
  @protocol_error "defprotocol and defimpl are not supported — define a plain module"
  @nested_error "nested module definitions are not permitted"
  @derive_error "@derive is not supported — protocols are consolidated when your beamlet is " <>
                  "built, so an implementation added later is never used. Convert the " <>
                  "struct instead, like Map.take(order, [:id, :total]) before Jason.encode!/1"

  @doc """
  Scans an `eval` buffer under the policy. Returns `:ok`, or every
  violation found, one per line as `line N: message` with the
  offending line quoted beneath it.
  """
  @spec scan_eval(String.t(), Policy.t()) :: :ok | {:error, String.t()}
  def scan_eval(code, %Policy{} = policy) do
    with {:ok, ast} <- parse(code, nil, 0) do
      ast |> walk(policy, :eval, MapSet.new()) |> render(code, nil, 0)
    end
  end

  @doc """
  Scans the source of `module` under the policy. Returns `:ok`, or
  every violation found, one per line with the offending line quoted
  beneath it.

  The source is the one top-level `defmodule` that
  `Beamlet.Code.Entry.module/1` found, and anything beside it is
  refused: expressions, protocols, and module definitions nested in
  its body. The module is granted to itself, and its own functions
  are known as locals.

  `opts[:file]` is the locator prefix, the module's path relative to
  the code dir, so a violation reads `lib/shopping/list.ex:4:
  message`; without it the prefix is `line 4:`.
  """
  @spec scan_define(String.t(), module(), Policy.t(), keyword()) :: :ok | {:error, String.t()}
  def scan_define(code, module, %Policy{} = policy, opts \\ []) when is_atom(module) do
    file = Keyword.get(opts, :file)
    context = Keyword.get(opts, :context, 0)

    with {:ok, ast} <- parse(code, file, context) do
      {locals, structure_violations} = structure(ast, module, policy)
      policy = Policy.grant(policy, [module])

      (walk(ast, policy, :define, locals) ++ structure_violations)
      |> render(code, file, context)
    end
  end

  @doc """
  Renders a violation at `line` of `code` as the scanner renders its
  own: the locator, the message, and the offending line quoted
  beneath. `file` is the locator prefix as in `scan_define/4`.

  `opts[:context]` is how many lines to quote either side of the
  offending one, for text the reader cannot otherwise see; the block
  then carries a line-number gutter so the offending line is
  identifiable. The default quotes the one line, trimmed.
  """
  @spec locate(String.t(), Path.t() | nil, non_neg_integer(), String.t(), keyword()) ::
          String.t()
  def locate(code, file, line, message, opts \\ []) do
    prefix = if file, do: "#{file}:#{line}", else: "line #{line}"

    case quoted(code, line, Keyword.get(opts, :context, 0)) do
      nil -> "#{prefix}: #{message}"
      quoted -> "#{prefix}: #{message}\n#{quoted}"
    end
  end

  defp parse(code, file, context) do
    {:ok, code |> Code.string_to_quoted!() |> normalize_pipes()}
  rescue
    e in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      {:error, locate(code, file, e.line, e.description, context: context)}
  end

  # `a |> Foo.bar(x)` carries Foo.bar/1 in the AST but calls Foo.bar/2.
  # Rewriting every pipe first means the walk only ever sees calls at
  # their effective arity, and no node handler needs to know pipes
  # exist.
  defp normalize_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, meta, [lhs, rhs]} ->
        try do
          Macro.pipe(lhs, rhs, 0)
        rescue
          ArgumentError ->
            {:__scan_violation__, meta, ["cannot pipe into #{Macro.to_string(rhs)}"]}
        end

      node ->
        node
    end)
  end

  defp walk(ast, policy, mode, locals) do
    acc = %{
      policy: policy,
      mode: mode,
      locals: locals,
      aliases: %{},
      imported: MapSet.new(),
      imported_all: [],
      violations: []
    }

    {_ast, acc} = Macro.prewalk(ast, acc, &handle/2)
    acc.violations
  end

  defp render([], _code, _file, _context), do: :ok

  defp render(violations, code, file, context) do
    message =
      violations
      |> Enum.reverse()
      |> Enum.sort_by(fn {line, _message} -> line end)
      |> Enum.map_join("\n", fn {line, message} ->
        locate(code, file, line, message, context: context)
      end)

    {:error, message}
  end

  defp quoted(_code, line, _context) when line < 1, do: nil

  defp quoted(code, line, 0) do
    case code |> String.split("\n") |> Enum.at(line - 1) do
      nil -> nil
      text -> text |> String.trim() |> blank_to_nil() |> indent()
    end
  end

  defp quoted(code, line, context) do
    lines = code |> String.trim_trailing("\n") |> String.split("\n")
    first = max(line - context, 1)
    last = min(line + context, length(lines))

    if first > last do
      nil
    else
      width = last |> Integer.to_string() |> String.length()

      lines
      |> Enum.slice((first - 1)..(last - 1)//1)
      |> Enum.with_index(first)
      |> Enum.map_join("\n", fn {text, number} ->
        gutter = number |> Integer.to_string() |> String.pad_leading(width)
        String.trim_trailing("    #{gutter} | #{text}")
      end)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp indent(nil), do: nil
  defp indent(text), do: "    " <> text

  # ── Define structure pass ─────────────────────────────────────────

  # Refuses every top-level form beside the entry's one defmodule,
  # and collects every function name/arity its body defines: function
  # heads look like local calls to the walk, and a function the module
  # defines may shadow a denied Kernel import.
  defp structure(ast, module, policy) do
    forms =
      case ast do
        {:__block__, _meta, forms} -> forms
        form -> [form]
      end

    acc = %{locals: MapSet.new(), policy: policy, violations: []}
    acc = Enum.reduce(forms, acc, &top_level(&1, module, &2))
    {acc.locals, acc.violations}
  end

  defp top_level({:defmodule, _meta, [_name, [{:do, body} | _]]}, module, acc) do
    scan_body(body, module, acc)
  end

  defp top_level({form, meta, _args}, _module, acc) when form in [:defprotocol, :defimpl] do
    violation(acc, meta, @protocol_error)
  end

  defp top_level({_form, meta, _args}, _module, acc), do: violation(acc, meta, @expression_error)
  defp top_level(_literal, _module, acc), do: violation(acc, [], @expression_error)

  defp scan_body(body, module, acc) do
    {_body, acc} =
      Macro.prewalk(body, acc, fn
        {:defmodule, meta, [target | _]} = node, acc ->
          {node, violation(acc, meta, nested_error(module, target))}

        {form, meta, _args} = node, acc when form in [:defprotocol, :defimpl] ->
          {node, violation(acc, meta, @protocol_error)}

        {def_kind, meta, [head | _]} = node, acc when def_kind in [:defmacro, :defmacrop] ->
          acc =
            if acc.policy.rules.allow_defmacro,
              do: acc,
              else: violation(acc, meta, defmacro_error(def_kind))

          {node, add_local(acc, head)}

        {def_kind, _meta, [head | _]} = node, acc
        when def_kind in [:def, :defp, :defdelegate, :defguard, :defguardp] ->
          {node, add_local(acc, head)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp nested_error(outer, {:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      name = Module.concat([outer | parts])
      "define #{inspect(name)} as its own top-level defmodule — #{@nested_error}"
    else
      @nested_error
    end
  end

  defp nested_error(_outer, _target), do: @nested_error

  defp add_local(acc, {:when, _meta, [head | _guards]}), do: add_local(acc, head)

  defp add_local(acc, {name, _meta, args}) when is_atom(name) do
    {required, total} = arity_range(args)
    locals = Enum.reduce(required..total, acc.locals, &MapSet.put(&2, {name, &1}))
    %{acc | locals: locals}
  end

  defp add_local(acc, _head), do: acc

  defp arity_range(nil), do: {0, 0}

  defp arity_range(args) when is_list(args) do
    total = length(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    {total - defaults, total}
  end

  # ── Node handlers ─────────────────────────────────────────────────

  # A handler returns the node the walk descends into next, so its
  # return decides what goes unscanned: `{node, acc}` walks every
  # child, `walk_only(children, acc)` walks only those listed, and
  # `skip(acc)` walks nothing below. A handler skips only what it has
  # checked itself; anything else in the subtree must be walked.
  defp skip(acc), do: {:ok, acc}
  defp walk_only(children, acc), do: {{:__block__, [], children}, acc}

  defp handle({:__scan_violation__, meta, [message]}, acc) do
    skip(violation(acc, meta, message))
  end

  # In define mode the structure pass owns every module-definition
  # shape rule; the nodes pass through so their bodies are walked.
  defp handle({form, _meta, _args} = node, %{mode: :define} = acc)
       when form in [:defmodule, :defprotocol, :defimpl] do
    {node, acc}
  end

  defp handle({form, meta, _args}, acc) when form in [:defmodule, :defprotocol, :defimpl] do
    skip(violation(acc, meta, eval_defmodule_error(acc.policy)))
  end

  defp handle({:alias, meta, args}, acc), do: skip(handle_alias(args, meta, acc))

  defp handle({:import, meta, args}, acc), do: skip(handle_import(args, meta, acc))

  defp handle({:require, meta, args}, acc), do: skip(handle_require(args, meta, acc))

  defp handle({:use, meta, [target | rest]}, acc) do
    acc = check_module_target(acc, meta, target, :use)
    walk_only(rest, acc)
  end

  # &Mod.fun/2 is a no-parens zero-arg call in the AST; check it at
  # the captured arity, not at zero.
  defp handle({:&, _meta, [{:/, meta, [{{:., _, [target, fun]}, _, []}, arity]}]}, acc)
       when is_atom(fun) and is_integer(arity) do
    case literal_module(target, acc.aliases) do
      {:ok, module} ->
        skip(check_remote(acc, meta, module, fun, arity))

      :error ->
        if acc.policy.rules.allow_dynamic_dispatch do
          walk_only([target], acc)
        else
          skip(
            violation(
              acc,
              meta,
              "capture target must be a literal module, got: " <>
                "&#{Macro.to_string(target)}.#{fun}/#{arity}"
            )
          )
        end
    end
  end

  defp handle({:&, _meta, [{:/, meta, [{fun, _, ctx}, arity]}]}, acc)
       when is_atom(fun) and is_atom(ctx) and is_integer(arity) do
    skip(check_local(acc, meta, fun, arity))
  end

  # defdelegate's to: target sits in data position, but each head is
  # a real call into it, so the delegated name/arity (honouring as:)
  # is checked against the grants. The heads keep walking, since
  # default values may carry expressions; the options are consumed.
  defp handle({:defdelegate, meta, [heads, opts]}, acc) when is_list(opts) do
    heads = List.wrap(heads)

    acc =
      case Keyword.fetch(opts, :to) do
        :error ->
          # A missing to: is the compiler's own error.
          acc

        {:ok, target} ->
          case literal_module(target, acc.aliases) do
            {:ok, module} ->
              Enum.reduce(heads, acc, &check_delegate(&2, meta, module, &1, opts[:as]))

            :error ->
              violation(acc, meta, "defdelegate to: must be a literal module")
          end
      end

    walk_only(heads, acc)
  end

  # The compile-hook attributes name a module whose code the compiler
  # invokes, a data-position target the walk must check. @behaviour is
  # deliberately not here: it names a module but never runs its code.
  defp handle({:@, _at_meta, [{attr, meta, [target]}]}, acc)
       when attr in [:before_compile, :after_compile, :after_verify, :on_definition] do
    arity = %{before_compile: 1, after_compile: 2, after_verify: 1, on_definition: 6}[attr]

    case target do
      {mod, fun} when is_atom(fun) ->
        case literal_module(mod, acc.aliases) do
          {:ok, module} -> skip(check_remote(acc, meta, module, fun, arity))
          :error -> skip(violation(acc, meta, "@#{attr} target must be a literal module"))
        end

      _module_form ->
        skip(check_module_target(acc, meta, target, "@#{attr}"))
    end
  end

  # @compile options reach the Erlang compiler, which calls the module
  # a parse or core transform names. The value must be literal, since
  # a computed one could build a transform key the check never sees.
  defp handle({:@, _at_meta, [{:compile, meta, [value]}]}, acc) do
    cond do
      not literal_option?(value) ->
        skip(
          violation(
            acc,
            meta,
            "@compile takes a literal value, such as @compile {:inline, name: 1}"
          )
        )

      transform?(value) ->
        skip(
          violation(
            acc,
            meta,
            "@compile parse_transform and core_transform run code at compile time and are not " <>
              "allowed; a macro does the same job in Elixir"
          )
        )

      true ->
        skip(acc)
    end
  end

  defp handle({:@, _at_meta, [{:derive, meta, [_target]}]}, acc) do
    skip(violation(acc, meta, @derive_error))
  end

  defp handle({{:., _dot_meta, [target, fun]}, meta, args}, acc)
       when is_atom(fun) and is_list(args) do
    case literal_module(target, acc.aliases) do
      {:ok, module} ->
        walk_only(args, check_remote(acc, meta, module, fun, length(args)))

      :error ->
        cond do
          meta[:no_parens] == true and args == [] ->
            # `user.name`: map field access on a variable; passes.
            walk_only([target], acc)

          acc.policy.rules.allow_dynamic_dispatch ->
            walk_only([target | args], acc)

          true ->
            walk_only(
              [target | args],
              violation(
                acc,
                meta,
                "call target must be a literal module — " <>
                  "`#{Macro.to_string(target)}.#{fun}(...)` with a variable is not allowed"
              )
            )
        end
    end
  end

  defp handle({fun, meta, args} = node, acc) when is_atom(fun) and is_list(args) do
    arity = length(args)

    if Macro.special_form?(fun, arity),
      do: {node, acc},
      else: {node, check_local(acc, meta, fun, arity)}
  end

  defp handle(node, acc), do: {node, acc}

  # ── alias / import / require ──────────────────────────────────────

  @alias_error "unsupported alias form — write `alias Foo.Bar`"

  defp handle_alias([target], meta, acc), do: record_alias(acc, meta, target, nil)

  defp handle_alias([target, opts], meta, acc) when is_list(opts) do
    record_alias(acc, meta, target, opts[:as])
  end

  defp handle_alias(_args, meta, acc), do: violation(acc, meta, @alias_error)

  defp record_alias(acc, meta, {{:., _, [{:__aliases__, _, prefix}, :{}]}, _, targets}, nil) do
    Enum.reduce(targets, acc, fn
      {:__aliases__, _, parts}, acc when is_list(parts) ->
        record_alias(acc, meta, {:__aliases__, [], prefix ++ parts}, nil)

      _other, acc ->
        violation(acc, meta, @alias_error)
    end)
  end

  defp record_alias(acc, meta, {:__aliases__, _, parts} = target, as) do
    with {:ok, module} <- literal_module(target, acc.aliases),
         {:ok, key} <- alias_key(parts, as) do
      %{acc | aliases: Map.put(acc.aliases, key, module)}
    else
      :error -> violation(acc, meta, @alias_error)
    end
  end

  defp record_alias(acc, meta, _target, _as), do: violation(acc, meta, @alias_error)

  defp alias_key(parts, nil), do: {:ok, List.last(parts)}
  defp alias_key(_parts, {:__aliases__, _, [name]}) when is_atom(name), do: {:ok, name}
  defp alias_key(_parts, _as), do: :error

  defp handle_import([target], meta, acc), do: import_module(acc, meta, target, [])

  defp handle_import([target, opts], meta, acc) when is_list(opts) do
    import_module(acc, meta, target, opts)
  end

  defp handle_import(_args, meta, acc) do
    violation(
      acc,
      meta,
      "unsupported import form — write `import Foo` or `import Foo, only: [...]`"
    )
  end

  defp import_module(acc, meta, target, opts) do
    case literal_module(target, acc.aliases) do
      {:ok, module} -> import_entry(acc, meta, module, opts, Policy.fetch(acc.policy, module))
      :error -> violation(acc, meta, "import target must be a literal module")
    end
  end

  defp import_entry(acc, meta, module, _opts, :error) do
    violation(acc, meta, "import #{inspect(module)} — #{denied_module(acc.policy, module)}")
  end

  defp import_entry(acc, meta, module, opts, {:ok, entry}) do
    case Keyword.fetch(opts, :only) do
      {:ok, fas} when is_list(fas) ->
        import_fas(acc, meta, module, fas)

      _selector_or_absent when entry == :all ->
        %{acc | imported_all: [module | acc.imported_all]}

      _restricted ->
        violation(
          acc,
          meta,
          "import #{inspect(module)} must list allowed functions explicitly, " <>
            "e.g. `import #{inspect(module)}, only: [...]` — the module is only " <>
            "partially permitted by your policy"
        )
    end
  end

  defp import_fas(acc, meta, module, fas) do
    if Keyword.keyword?(fas) and Enum.all?(fas, fn {_f, a} -> is_integer(a) end) do
      Enum.reduce(fas, acc, fn {fun, arity}, acc ->
        if Policy.allowed?(acc.policy, module, fun, arity),
          do: %{acc | imported: MapSet.put(acc.imported, {fun, arity})},
          else: violation(acc, meta, denied_remote(acc, module, fun, arity))
      end)
    else
      violation(
        acc,
        meta,
        "import only: entries are `function: arity` pairs, e.g. only: [puts: 1]"
      )
    end
  end

  defp handle_require([target], meta, acc) do
    check_module_target(acc, meta, target, :require)
  end

  defp handle_require([target, opts], meta, acc) when is_list(opts) do
    acc = check_module_target(acc, meta, target, :require)

    case {literal_module(target, acc.aliases), opts[:as]} do
      {{:ok, module}, {:__aliases__, _, [name]}} when is_atom(name) ->
        %{acc | aliases: Map.put(acc.aliases, name, module)}

      _no_alias ->
        acc
    end
  end

  defp handle_require(_args, meta, acc) do
    violation(acc, meta, "unsupported require form — write `require Foo`")
  end

  defp check_module_target(acc, meta, target, form) do
    case literal_module(target, acc.aliases) do
      {:ok, module} ->
        if Policy.allowed?(acc.policy, module),
          do: acc,
          else:
            violation(
              acc,
              meta,
              "#{form} #{inspect(module)} — #{denied_module(acc.policy, module)}"
            )

      :error ->
        violation(acc, meta, "#{form} target must be a literal module")
    end
  end

  # ── Checks ────────────────────────────────────────────────────────

  defp check_remote(acc, meta, Kernel, fun, _arity)
       when fun in [:defmodule, :defprotocol, :defimpl] do
    message =
      case acc.mode do
        :eval -> eval_defmodule_error(acc.policy)
        :define -> @nested_error
      end

    violation(acc, meta, message)
  end

  # The qualified spelling of the defmacro rule: `Kernel.defmacro`
  # inside a module body defines a macro like the bare form does.
  defp check_remote(%{mode: :define} = acc, meta, Kernel, fun, _arity)
       when fun in [:defmacro, :defmacrop] do
    if acc.policy.rules.allow_defmacro,
      do: acc,
      else: violation(acc, meta, defmacro_error(fun))
  end

  defp check_remote(acc, meta, module, fun, arity) do
    if Policy.allowed?(acc.policy, module, fun, arity),
      do: acc,
      else: violation(acc, meta, denied_remote(acc, module, fun, arity))
  end

  defp check_delegate(acc, meta, module, {name, _head_meta, args}, as) when is_atom(name) do
    fun = if is_atom(as) and not is_nil(as), do: as, else: name
    {required, total} = arity_range(args)

    Enum.reduce(required..total, acc, fn arity, acc ->
      check_remote(acc, meta, module, fun, arity)
    end)
  end

  defp check_delegate(acc, _meta, _module, _head, _as), do: acc

  defp check_local(acc, meta, fun, arity) do
    cond do
      # The scanned code's own functions come first: a local may shadow a
      # denied Kernel import, and function heads read as local calls.
      MapSet.member?(acc.locals, {fun, arity}) ->
        acc

      MapSet.member?(acc.imported, {fun, arity}) ->
        acc

      Enum.any?(acc.imported_all, &exports?(&1, fun, arity)) ->
        acc

      exports?(Kernel, fun, arity) ->
        if Policy.allowed?(acc.policy, Kernel, fun, arity),
          do: acc,
          else: violation(acc, meta, "#{fun}/#{arity} #{not_permitted(acc.policy, Kernel, fun)}")

      true ->
        # An unknown local is an eval-time undefined-function error,
        # not a policy question.
        acc
    end
  end

  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, fun, arity) or macro_exported?(module, fun, arity))
  end

  # __MODULE__ can only ever denote the module being defined, granted
  # by construction, so it resolves to the sentinel the default grants
  # as :all.
  defp literal_module({:__MODULE__, _, ctx}, _aliases) when is_atom(ctx), do: {:ok, :__MODULE__}

  defp literal_module({:__aliases__, _, [first | rest] = parts}, aliases) do
    cond do
      not Enum.all?(parts, &is_atom/1) -> :error
      Map.has_key?(aliases, first) -> {:ok, Module.concat([aliases[first] | rest])}
      true -> {:ok, Module.concat(parts)}
    end
  end

  defp literal_module(module, _aliases) when is_atom(module) and not is_nil(module),
    do: {:ok, module}

  defp literal_module(_target, _aliases), do: :error

  defp literal_option?(value) when is_atom(value) or is_number(value) or is_binary(value),
    do: true

  defp literal_option?(value) when is_list(value), do: Enum.all?(value, &literal_option?/1)
  defp literal_option?({left, right}), do: literal_option?(left) and literal_option?(right)
  defp literal_option?({:{}, _, elems}), do: Enum.all?(elems, &literal_option?/1)
  defp literal_option?({:__aliases__, _, parts}), do: Enum.all?(parts, &is_atom/1)
  defp literal_option?(_value), do: false

  defp transform?({key, _}) when key in [:parse_transform, :core_transform], do: true
  defp transform?(value) when is_list(value), do: Enum.any?(value, &transform?/1)
  defp transform?({left, right}), do: transform?(left) or transform?(right)
  defp transform?({:{}, _, elems}), do: Enum.any?(elems, &transform?/1)
  defp transform?(_value), do: false

  # ── Error copy ────────────────────────────────────────────────────

  @doc """
  The copy for a module the policy denies, with its signage hint:
  `File is not permitted by your policy — Host.File provides scoped
  file access`. A name nothing answers to is not a policy matter, so
  it reads `nothing named X exists on your beamlet` instead, since
  "not permitted" for a module that was never defined teaches the
  wrong lesson. Shared with discovery, so a refused `print_docs`
  says what a refused call does.
  """
  @spec denied_module(Policy.t(), module()) :: String.t()
  def denied_module(%Policy{} = policy, module) do
    cond do
      Code.ensure_loaded?(module) ->
        "#{inspect(module)} is not permitted by your policy#{hint(Signage.hint(policy, module))}"

      host_name?(module) ->
        "nothing named #{inspect(module)} exists on your beamlet — " <>
          "Host.Code.print_modules() lists the Host modules and Host.Code.print_docs(Module) " <>
          "their functions"

      true ->
        "nothing named #{inspect(module)} exists on your beamlet — " <>
          "check the name, or define it first"
    end
  end

  # A guessed Host module is a model looking for the stdlib, not a
  # module it meant to define.
  defp host_name?(module), do: match?(["Host" | _], Module.split(module))

  @doc """
  The copy for a function the policy denies of a module it grants in
  part, with its signage hint, to follow the target being refused:
  `is not permitted by your policy — process primitives are withheld
  as a family`.
  """
  @spec not_permitted(Policy.t(), module(), atom()) :: String.t()
  def not_permitted(%Policy{} = policy, module, fun) do
    "is not permitted by your policy#{hint(Signage.hint(policy, module, fun))}"
  end

  defp denied_remote(acc, module, fun, arity) do
    target = "#{inspect(module)}.#{fun}/#{arity}"

    if Policy.allowed?(acc.policy, module),
      do: "#{target} #{not_permitted(acc.policy, module, fun)}",
      else: "#{target} — #{denied_module(acc.policy, module)}"
  end

  defp hint(nil), do: ""
  defp hint(copy), do: " — #{copy}"

  defp defmacro_error(form), do: "#{form} is not permitted by your policy"

  defp violation(acc, meta, message) do
    line = if is_list(meta), do: Keyword.get(meta, :line, 0), else: 0
    %{acc | violations: [{line, message} | acc.violations]}
  end

  # Whether the redirect names a door the token has: a policy with no
  # define tool gets told so, rather than sent to a tool it cannot see.
  defp eval_defmodule_error(%Policy{tools: tools}) do
    if :define in tools,
      do: @eval_defmodule_error <> @define_hint,
      else: @eval_defmodule_error <> @no_define_hint
  end
end
