defmodule Beamlet.Policy do
  @moduledoc """
  A policy: what a token's requests may do on your beamlet.

  Three parts. **Tools** are which of the MCP tools the token may
  use, `define` and `eval`. **Rules** are the shape rules on the code
  it submits (`Beamlet.Policy.Rules`). **Grants** are the modules and
  functions its code may call: a module maps to everything, an
  `only` list or an `except` list, and a module absent from the
  table is denied.

  Beamlet ships one policy, `default` (`Beamlet.Policy.Default`
  records its rulings). A token runs under it when it names no
  policy, and every other policy builds on it. Declare the others in
  application config and restart; there is no reload:

      config :beamlet,
        policies: [
          explorer: [
            tools: [:eval],
            rules: [allow_dynamic_dispatch: true],
            allow: [Task, {File, only: [read: 1]}],
            deny: [Host.Repo, Req, Req.Request]
          ]
        ]

  Applied to the default in this order:

  - `tools` replaces the default's list when given. An empty list is
    accepted.
  - `rules` merges: a rule given overrides, a rule absent stays
    strict, an unknown rule fails the boot.
  - `allow` replaces the module's entry wholesale, the default's
    included, so `allow: [Kernel]` re-enables `apply`. `only:` and
    `except:` are relative to the module's full surface.
  - `deny` removes the module's entry. It applies after `allow`, so
    a module in both is denied. Denying a module nothing grants is a
    no-op.

  Every module named must be loadable on the beamlet and every
  function under `only:` or `except:` must exist at that arity, so a
  typo fails the boot rather than granting nothing. A module named
  twice in one key is an error. Agent-defined modules are granted by
  existence and never need an `allow`. Policy names follow the user
  and token rule, lowercase letters, digits, underscores and hyphens;
  `default` is reserved.

  ## What a relaxed rule reaches

  The pool of defined modules is shared by every token, so a rule
  relaxed for one policy is felt by all:

  - `allow_defmacro: true` lets the token define macros. A macro
    expands inside whichever module uses it, under that author's
    policy, so whatever this policy grants reaches every other token
    through the macros it writes.
  - `allow_dynamic_dispatch: true` lets call targets be computed
    (`mod.fun()` with `mod` a variable), which the scanner cannot
    resolve. The grants then stop meaning what they say for this
    policy's code, since any loaded module is one variable away.

  Give either to a token you would trust with the whole beamlet.
  """

  alias Beamlet.Policy.Default
  alias Beamlet.Policy.Rules

  defstruct [:name, tools: [:define, :eval], rules: %Rules{}, grants: %{}]

  @typedoc "A function name/arity pair, the grants' granularity."
  @type fa :: {atom(), arity()}

  @typedoc "A module's grant: everything, a closed list, or all but."
  @type entry :: :all | {:only, [fa()]} | {:except, [fa()]}

  @typedoc "The grant table. Absence means denied."
  @type grants :: %{module() => entry()}

  @typedoc "An MCP tool a policy may grant."
  @type tool :: :define | :eval

  @typedoc "A built policy."
  @type t :: %__MODULE__{
          name: String.t(),
          tools: [tool()],
          rules: Rules.t(),
          grants: grants()
        }

  @tools [:define, :eval]
  @keys [:tools, :rules, :allow, :deny]
  @name ~r/^[a-z0-9_-]{1,64}$/

  @doc "The tools a policy may grant."
  @spec tools() :: [tool()]
  def tools, do: @tools

  @doc "The policy Beamlet ships: both tools, strict rules, the curated grants."
  @spec default() :: t()
  def default do
    %__MODULE__{name: "default", tools: @tools, rules: %Rules{}, grants: Default.grants()}
  end

  @doc """
  Builds a declared policy from its document, on top of the default.

  The name is a string or atom. The document is a keyword list with
  any of `tools`, `rules`, `allow` and `deny`, as the moduledoc
  describes. An error names the policy and the key at fault.
  """
  @spec build(String.t() | atom(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(name, document) do
    name = to_string(name)

    with :ok <- validate_name(name),
         :ok <- validate_document(name, document),
         :ok <- validate_tools(name, Keyword.fetch(document, :tools)),
         :ok <- validate_rules(name, Keyword.fetch(document, :rules)),
         {:ok, allow} <- validate_allow(name, Keyword.fetch(document, :allow)),
         {:ok, deny} <- validate_deny(name, Keyword.fetch(document, :deny)) do
      default = default()

      {:ok,
       %__MODULE__{
         name: name,
         tools: Keyword.get(document, :tools, default.tools),
         rules: struct!(default.rules, Keyword.get(document, :rules, [])),
         grants: default.grants |> Map.merge(Map.new(allow)) |> Map.drop(deny)
       }}
    end
  end

  @doc "Whether the module is granted at all (structs, require, use)."
  @spec allowed?(t(), module()) :: boolean()
  def allowed?(%__MODULE__{grants: grants}, module), do: Map.has_key?(grants, module)

  @doc "Whether the function is granted under the module's entry."
  @spec allowed?(t(), module(), atom(), arity()) :: boolean()
  def allowed?(%__MODULE__{grants: grants}, module, fun, arity) do
    case grants do
      %{^module => :all} -> true
      %{^module => {:only, fas}} -> {fun, arity} in fas
      %{^module => {:except, fas}} -> {fun, arity} not in fas
      _ -> false
    end
  end

  @doc "The module's entry, or `:error` when the module is denied."
  @spec fetch(t(), module()) :: {:ok, entry()} | :error
  def fetch(%__MODULE__{grants: grants}, module), do: Map.fetch(grants, module)

  @doc """
  Renders the policy as an agent or operator reads it: name and
  tools, the rules in force, the deliberate denials it has not
  re-granted with their reasons, and the modules granted only in
  part.

  The only listable answer to "what is disallowed", since everything
  absent from the grants is denied: the rendering covers the denials
  that are deliberate (`Beamlet.Policy.Default`'s signage) rather
  than the unbounded rest.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = policy) do
    denial_lines =
      for {_category, copy, modules} <- Default.denials_by_category(),
          denied = Enum.reject(modules, &allowed?(policy, &1)),
          denied != [] do
        "  #{Enum.map_join(denied, ", ", &inspect/1)}\n    — #{copy}"
      end

    partial_lines =
      policy.grants
      |> Enum.filter(fn {_mod, entry} -> entry != :all end)
      |> Enum.sort_by(fn {mod, _entry} -> inspect(mod) end)
      |> Enum.map(fn
        {mod, {:only, fas}} -> "  #{inspect(mod)} — only #{render_fas(fas)}"
        {mod, {:except, fas}} -> "  #{inspect(mod)} — all except #{render_fas(fas)}"
      end)

    Enum.join(
      [
        "Policy: #{policy.name}\nTools: #{render_tools(policy.tools)}",
        "Standard Elixir and Erlang are available; this is what the policy " <>
          "deliberately withholds. Anything else denied is simply not granted " <>
          "on your beamlet. Host.Code.print_modules() shows what is.",
        section("Rules for your code:", rule_lines(policy.rules), "(none)"),
        section("Not available:", denial_lines, "(nothing withheld)"),
        section("Partially granted:", partial_lines, "(none)")
      ],
      "\n\n"
    )
  end

  # ── Validation ────────────────────────────────────────────────────

  defp validate_name("default") do
    {:error,
     "policy default: the name is reserved for the policy Beamlet ships; " <>
       "declare another name and build on it with allow, deny, tools and rules"}
  end

  defp validate_name(name) do
    if Regex.match?(@name, name) do
      :ok
    else
      {:error,
       "policy #{inspect(name)}: names are lowercase letters, digits, underscores " <>
         "and hyphens, at most 64 characters"}
    end
  end

  defp validate_document(name, document) do
    cond do
      not Keyword.keyword?(document) ->
        {:error,
         "policy #{name}: a policy is a keyword list with tools, rules, allow and " <>
           "deny, got: #{inspect(document)}"}

      (unknown = Keyword.keys(document) -- @keys) != [] ->
        {:error,
         "policy #{name}: unknown key #{inspect(hd(unknown))} " <>
           "(a policy has tools, rules, allow and deny)"}

      true ->
        :ok
    end
  end

  defp validate_tools(_name, :error), do: :ok

  defp validate_tools(name, {:ok, tools}) do
    cond do
      not is_list(tools) or not Enum.all?(tools, &(&1 in @tools)) ->
        {:error,
         "policy #{name}: tools must be a list drawn from #{inspect(@tools)}, " <>
           "got: #{inspect(tools)}"}

      (dup = repeated(tools)) != nil ->
        {:error, "policy #{name}: tools names #{inspect(dup)} twice"}

      true ->
        :ok
    end
  end

  defp validate_rules(_name, :error), do: :ok

  defp validate_rules(name, {:ok, rules}) do
    if Keyword.keyword?(rules) do
      Enum.find_value(rules, :ok, fn
        {key, value}
        when key in [:allow_defmacro, :allow_dynamic_dispatch] and
               is_boolean(value) ->
          nil

        {key, value} ->
          if key in Rules.keys() do
            {:error, "policy #{name}: rule #{key} must be true or false, got: #{inspect(value)}"}
          else
            {:error,
             "policy #{name}: unknown rule #{inspect(key)} " <>
               "(rules are #{Enum.join(Rules.keys(), " and ")})"}
          end
      end)
    else
      {:error,
       "policy #{name}: rules must be a keyword list like [allow_defmacro: true], " <>
         "got: #{inspect(rules)}"}
    end
  end

  defp validate_allow(_name, :error), do: {:ok, []}

  defp validate_allow(name, {:ok, entries}) when is_list(entries) do
    with {:ok, allow} <- map_while_ok(entries, &allow_entry(name, &1)) do
      case repeated(Enum.map(allow, &elem(&1, 0))) do
        nil -> {:ok, allow}
        module -> {:error, "policy #{name}: allow names #{inspect(module)} twice"}
      end
    end
  end

  defp validate_allow(name, {:ok, other}) do
    {:error, "policy #{name}: allow must be a list of modules, got: #{inspect(other)}"}
  end

  defp allow_entry(name, {module, opts}) do
    with :ok <- validate_module(name, :allow, module),
         {:ok, entry} <- allow_options(name, module, opts) do
      {:ok, {module, entry}}
    end
  end

  defp allow_entry(name, module) when is_atom(module) do
    with :ok <- validate_module(name, :allow, module), do: {:ok, {module, :all}}
  end

  defp allow_entry(name, other) do
    {:error,
     "policy #{name}: allow entries are a module, {module, only: [...]} or " <>
       "{module, except: [...]}, got: #{inspect(other)}"}
  end

  defp allow_options(name, module, opts) do
    keys = if Keyword.keyword?(opts), do: Enum.sort(Keyword.keys(opts)), else: nil

    cond do
      keys == [:only] ->
        validate_fas(name, module, :only, opts[:only])

      keys == [:except] ->
        validate_fas(name, module, :except, opts[:except])

      keys == [:except, :only] ->
        {:error, "policy #{name}: allow #{inspect(module)} takes only: or except:, not both"}

      true ->
        {:error,
         "policy #{name}: allow #{inspect(module)} takes only: or except:, " <>
           "got: #{inspect(opts)}"}
    end
  end

  defp validate_fas(name, module, key, fas) do
    shaped? =
      Keyword.keyword?(fas) and fas != [] and
        Enum.all?(fas, fn {_fun, arity} -> is_integer(arity) and arity >= 0 end)

    if shaped? do
      case Enum.find(fas, fn {fun, arity} -> not exported?(module, fun, arity) end) do
        nil ->
          {:ok, {key, fas}}

        {fun, arity} ->
          {:error,
           "policy #{name}: allow #{inspect(module)} #{key}: #{fun}/#{arity} is not " <>
             "a function or macro of #{inspect(module)}"}
      end
    else
      {:error,
       "policy #{name}: allow #{inspect(module)} #{key}: must be a non-empty list " <>
         "of function: arity pairs, got: #{inspect(fas)}"}
    end
  end

  defp validate_deny(_name, :error), do: {:ok, []}

  defp validate_deny(name, {:ok, modules}) when is_list(modules) do
    with {:ok, _} <- map_while_ok(modules, &validate_module(name, :deny, &1)) do
      case repeated(modules) do
        nil -> {:ok, modules}
        module -> {:error, "policy #{name}: deny names #{inspect(module)} twice"}
      end
    end
  end

  defp validate_deny(name, {:ok, other}) do
    {:error, "policy #{name}: deny must be a list of modules, got: #{inspect(other)}"}
  end

  defp validate_module(name, key, module) do
    if is_atom(module) and Code.ensure_loaded?(module) do
      :ok
    else
      {:error,
       "policy #{name}: #{key} #{inspect(module)} is not a module on this beamlet " <>
         "(agent-defined modules never need an allow: existence is the grant)"}
    end
  end

  defp exported?(module, fun, arity) do
    function_exported?(module, fun, arity) or macro_exported?(module, fun, arity)
  end

  defp repeated(list), do: Enum.find(list, &(Enum.count(list, fn x -> x == &1 end) > 1))

  defp map_while_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :ok -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # ── Rendering ─────────────────────────────────────────────────────

  defp render_tools([]), do: "(none)"
  defp render_tools(tools), do: Enum.join(tools, ", ")

  # Only rules in force are listed: a relaxed rule says nothing, and
  # the rule names are operator configuration, not something an agent
  # can act on.
  defp rule_lines(%Rules{} = rules) do
    defmacro_line =
      if rules.allow_defmacro,
        do: [],
        else: ["  defmacro/defmacrop are not permitted in define"]

    dispatch_line =
      if rules.allow_dynamic_dispatch,
        do: [],
        else: ["  call targets must be literal modules"]

    defmacro_line ++ dispatch_line
  end

  defp render_fas(fas) do
    fas
    |> Enum.sort()
    |> Enum.map_join(", ", fn {fun, arity} -> "#{fun}/#{arity}" end)
  end

  defp section(title, [], empty), do: "#{title}\n  #{empty}"
  defp section(title, lines, _empty), do: Enum.join([title | lines], "\n")
end
