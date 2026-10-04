defmodule Beamlet.Policy do
  @moduledoc """
  A policy decides what a token's requests may do on your beamlet.

  Declare policies in config, by name:

      config :beamlet,
        policies: [
          explorer: [
            tools: [:eval],
            allow: [{Host.Code, except: [remove: 1]}],
            deny: [Host.HTTP]
          ]
        ]

  Then give one to a token, with `beamlet tokens.create laptop
  --policy explorer` or on the consent page when a chat client
  connects. A token with no policy named gets `default`.

  A policy keeps an agent to what you meant it to do. It is a
  guardrail, not a sandbox: code set on escaping it may succeed.

  ## Keys

  Every policy starts from `default` and changes only what it names.

  * `:tools` - The MCP tools the token gets: `:eval`, `:define` or
    both. `:define` brings the `patch` tool with it. Replaces the
    default's list, which has both.
  * `:rules` - Relaxes the rules on the code the token submits.
    There are two, `allow_defmacro` and `allow_dynamic_dispatch`,
    both off unless set to `true`.
  * `:allow` - Modules the token's code may call. A module alone
    grants all of it. `{Mod, only: [fun: 1]}` grants just the
    functions listed, and `{Mod, except: [fun: 1]}` all but those.
    An entry replaces whatever the default grants for that module,
    so `allow: [Kernel]` brings back `apply/2` and the rest the
    default holds back.
  * `:deny` - Modules the token's code may not call at all. A
    module in both `allow` and `deny` is denied.

  Tools and grants are separate. Without the `except`, `explorer`
  above could not define modules but could still delete them with
  `Host.Code.remove/1`.

  Modules agents define need no `allow`. Every token can call them,
  whichever token defined them.

  ## Applying and reading

  Every module and function a policy names must exist, so a typo
  stops the boot instead of granting nothing. A change takes a
  restart. A policy in the data dir's `config.exs` replaces any
  policy of the same name declared elsewhere
  (`Beamlet.Config.Provider`).

  `beamlet policies.show explorer` prints what a policy allows. Agent
  code reads its own with `Host.Code.print_policy/0`.

  > #### Relaxed rules reach every token {: .warning}
  >
  > `allow_defmacro` lets the token write macros. A macro writes code
  > into every module that uses it, so other tokens end up running
  > code this token wrote.
  >
  > `allow_dynamic_dispatch` lets code compute what it calls, as in
  > `mod.fun()` with `mod` a variable. Beamlet cannot check such a
  > call, so any module is within reach. Other tokens reach it too,
  > through the modules this token defines.
  >
  > Give either only to a token you would trust with the whole
  > beamlet.
  """

  alias Beamlet.Policy.Default
  alias Beamlet.Policy.Rules
  alias Beamlet.Policy.Signage

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
          rules: %Rules{},
          grants: grants()
        }

  @tools [:define, :eval]
  @keys [:tools, :rules, :allow, :deny]
  @name ~r/^[a-z0-9_-]{1,64}$/

  @doc """
  The MCP tools a policy puts in a token's tool list, in name order.

  `define` is two tools in one: a policy granting it lists the
  `define` and `patch` tools, since both write modules through the
  same pipeline under the same limit.
  """
  @spec tool_list(t()) :: [:define | :eval | :patch]
  def tool_list(%__MODULE__{tools: tools}) do
    tools
    |> Enum.flat_map(fn
      :define -> [:define, :patch]
      :eval -> [:eval]
    end)
    |> Enum.sort()
  end

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

  # The policy with every module in `modules` granted whole. The other
  # half of the effective grants: modules defined on the beamlet are
  # granted by existence, so the runtimes merge the defined set in
  # before every scan, and `define` and `patch` grant the modules of
  # one call to each other the same way.
  @doc false
  @spec grant(t(), [module()]) :: t()
  def grant(%__MODULE__{grants: grants} = policy, modules) do
    %{policy | grants: Map.merge(grants, Map.new(modules, &{&1, :all}))}
  end

  # Whether the module is granted at all, for structs, require and use.
  @doc false
  @spec allowed?(t(), module()) :: boolean()
  def allowed?(%__MODULE__{grants: grants}, module), do: Map.has_key?(grants, module)

  @doc false
  @spec allowed?(t(), module(), atom(), arity()) :: boolean()
  def allowed?(%__MODULE__{grants: grants}, module, fun, arity) do
    case grants do
      %{^module => :all} -> true
      %{^module => {:only, fas}} -> {fun, arity} in fas
      %{^module => {:except, fas}} -> {fun, arity} not in fas
      _ -> false
    end
  end

  @doc false
  @spec fetch(t(), module()) :: {:ok, entry()} | :error
  def fetch(%__MODULE__{grants: grants}, module), do: Map.fetch(grants, module)

  @doc """
  Renders the policy as an agent or operator reads it: name and
  tools, the rules in force, the deliberate denials it has not
  re-granted with their reasons, and the modules granted only in
  part.

  The only listable answer to "what is disallowed", since everything
  absent from the grants is denied: the rendering covers the denials
  that carry teaching copy rather than the unbounded rest.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = policy) do
    denial_lines =
      for {copy, modules} <- Signage.denials(policy) do
        "  #{Enum.map_join(modules, ", ", &inspect/1)}\n    — #{copy}"
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
        "Policy: #{policy.name}\nTools: #{render_tools(policy)}",
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

  # The one place that names every tool and says which this policy
  # withholds, so the static copy elsewhere can name tools plainly.
  defp render_tools(policy) do
    case tool_list(policy) do
      [] ->
        "(none)"

      granted ->
        case tool_list(%__MODULE__{name: "default", tools: @tools}) -- granted do
          [] -> Enum.join(granted, ", ")
          withheld -> "#{Enum.join(granted, ", ")} (not granted: #{Enum.join(withheld, ", ")})"
        end
    end
  end

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
