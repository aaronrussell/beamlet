defmodule Host.Code do
  @moduledoc """
  Discover what is on your beamlet, read its docs and source, and
  remove modules.

  Start with `print_modules/0`. The `print_*` functions print what
  they find and return `:ok`; `remove/1` acts silently and returns
  `:ok`. A failure raises with a teaching message, like any other
  error, and everything printed before it survives.

  Explore with `eval`, then build with `define` and edit with `patch`:
  anything worth calling again belongs in a module. Each `eval` starts
  clean, so read what exists first. Other agents and clients share the
  same pool of modules, and this is how you see its current state. A
  defined module is read whole with `print_source/1`, or in pieces:
  `print_outline/1` for its shape, then `print_source/2` and
  `print_source/3` for one function or a range of lines.

  Everything here acts as you, the token behind the `eval`: the
  listing and the docs are filtered by your policy, and a removal is
  recorded against you. Called from anywhere else, a web request or
  a process of your own, there is no one to act as, and each function
  raises saying so.
  """

  alias Beamlet.Code.Discovery
  alias Beamlet.Policies
  alias Beamlet.Policy
  alias Beamlet.Principal

  @doc """
  Prints the discoverable module surface of your beamlet.

  Four groups, each with a one-line description: the modules defined
  with `define`, the `Host.*` modules your beamlet provides, the
  framework modules you write pages and data against, and the
  libraries it ships. Standard Elixir and Erlang are not listed; they
  are available unless your policy says otherwise
  (`print_policy/0`). Migrations and routes have listings of their
  own, `Host.Migrator.print_migrations/0` and
  `Host.Router.print_routes/0`, which the footer points at.
  """
  @spec print_modules() :: :ok
  def print_modules, do: print(Discovery.list(policy!(:print_modules)))

  @doc """
  Prints what your policy deliberately withholds, the rules in force
  for your code, and the modules granted only in part.

  Everything not listed by `print_modules/0` and not standard
  Elixir/Erlang is denied by default; this shows the denials that
  are deliberate and the reason for each.
  """
  @spec print_policy() :: :ok
  def print_policy do
    {:ok, policy} = Policies.fetch(Principal.current!("Host.Code.print_policy").policy)
    print({:ok, Policy.render(policy)})
  end

  @doc """
  Prints a module's documentation, e.g. `print_docs(Host.Code)`.

  Shows the moduledoc and an index of the public functions with
  one-line summaries. Works for any module you are permitted to
  call. For a function's full documentation use `print_docs/2` or
  `print_docs/3`.
  """
  @spec print_docs(module()) :: :ok
  def print_docs(module) when is_atom(module) do
    print(Discovery.doc(policy!(:print_docs), module))
  end

  @doc """
  Prints full documentation for every arity of a function, e.g.
  `print_docs(Enum, :map)`.
  """
  @spec print_docs(module(), atom()) :: :ok
  def print_docs(module, function) when is_atom(module) and is_atom(function) do
    print(Discovery.doc(policy!(:print_docs), module, function))
  end

  @doc """
  Prints full documentation for one arity of a function, e.g.
  `print_docs(Enum, :map, 2)`.
  """
  @spec print_docs(module(), atom(), arity()) :: :ok
  def print_docs(module, function, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 do
    print(Discovery.doc(policy!(:print_docs), module, function, arity))
  end

  @doc """
  Prints the outline of a module defined with `define`: each
  top-level item with the lines it spans.

  One row per item, e.g. `10-17  def total/1 (2 clauses)`: a
  function's row covers all its clauses and the `@doc`, `@spec`,
  `@impl`, `attr` and `slot` directly above them, which is exactly
  what a `patch` `select` touches; a type's row covers its
  `@typedoc`. `use`, `import`, `alias`, `defstruct` and any other
  top-level form show by their first line. The moduledoc
  and attributes holding values have no row, so a gap between rows
  is one of those: read it by line range. Read the outline first,
  then the piece you need with `print_source/2` or `print_source/3`.
  Serves defined modules only.
  """
  @spec print_outline(module()) :: :ok
  def print_outline(module) when is_atom(module) do
    print(Discovery.outline(policy!(:print_outline), module))
  end

  @doc """
  Prints the source code of a module previously defined with
  `define`.

  Source is stored as the formatter lays it out, so the layout may
  differ from what was sent. Errors and stack traces locate as
  `lib/shopping/list.ex:42`: the module's path, and a line of what
  this prints. For a long module read `print_outline/1` and then a
  function or a line range with `print_source/2`. Read a module
  before replacing or patching it. Serves defined modules only; for
  anything else use `print_docs/1`.
  """
  @spec print_source(module()) :: :ok
  def print_source(module) when is_atom(module) do
    print(Discovery.source(policy!(:print_source), module))
  end

  @doc """
  Prints one function of a defined module at every arity, or a range
  of its lines, e.g. `print_source(Shopping.List, :total)` or
  `print_source(Shopping.List, 40..80)`.

  A function prints as its whole block, all clauses and the docs
  above them, exactly as stored, so text copied from it is what a
  `patch` `find` matches. A range is inclusive and counts from line 1, as
  `print_outline/1` shows; an end past the last line prints to the
  end.
  """
  @spec print_source(module(), atom() | Range.t()) :: :ok
  def print_source(module, function) when is_atom(module) and is_atom(function) do
    print(Discovery.function(policy!(:print_source), module, function, :any))
  end

  def print_source(module, %Range{first: first, last: last, step: 1} = range)
      when is_atom(module) and first >= 1 and last >= first do
    print(Discovery.lines(policy!(:print_source), module, range))
  end

  def print_source(module, %Range{}) when is_atom(module) do
    raise "Host.Code.print_source takes an ascending range of lines, " <>
            "e.g. print_source(Shopping.List, 40..80)"
  end

  @doc """
  Prints one arity of a function of a defined module, e.g.
  `print_source(Shopping.List, :total, 1)`.
  """
  @spec print_source(module(), atom(), arity()) :: :ok
  def print_source(module, function, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 do
    print(Discovery.function(policy!(:print_source), module, function, arity))
  end

  @doc """
  Removes modules defined with `define`, e.g. `remove(Shopping.List)`.

  The modules are unloaded from your beamlet and their files
  deleted. Accepts a module or a list of modules removed together as one
  atomic set. Removal is refused while any module outside the set
  depends on a target; the error names the dependents. Remove or
  rework dependents first, or pass the whole group in one call:
  modules that call each other can only be removed together.
  """
  @spec remove(module() | [module()]) :: :ok
  def remove(module) when is_atom(module), do: remove([module])

  def remove(modules) when is_list(modules) do
    unless Enum.all?(modules, &is_atom/1) do
      raise "Host.Code.remove takes a module or a list of modules, e.g. remove(Shopping.List)"
    end

    case Beamlet.Code.remove(modules, Principal.current!("Host.Code.remove")) do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  # The effective policy: the principal's with the defined modules
  # granted by existence, as the runtimes build it before a scan.
  defp policy!(fun) do
    {:ok, policy} = Policies.fetch(Principal.current!("Host.Code.#{fun}").policy)
    Policy.grant(policy, Beamlet.Code.defined())
  end

  defp print({:ok, text}) do
    IO.puts(text)
    :ok
  end

  # A printed error is camouflaged among printed successes, and a
  # mid-script return value is invisible; raising makes the failure
  # unmistakable while eval keeps everything printed before it.
  defp print({:error, message}), do: raise(message)
end
