defmodule Beamlet.Code.Tracer do
  @moduledoc false

  # The compiler tracer for the code server's compiles. It records the
  # dependency map and nothing else: the scanner is the only policy
  # gate, applied when code is submitted, and boot compiles carry none.
  #
  # Tracers are a VM-global compiler option and the compiler calls
  # trace/2 from every compiling process, so the tracer finds its
  # context in the code server's table rather than in any process:
  # which files belong to the compile in flight, so other compiles in
  # the VM pass through untouched, and which module names count as
  # defined, so only edges between defined modules are recorded. It
  # is a no-op unless a context is installed.
  #
  # Two kinds of record land in the table, both scoped to defined
  # modules. Compile-time edges, from struct expansions, remote and
  # imported macros, imported functions and requires, are what
  # compilation bakes in; they drive replace's dependent recompiles.
  # Runtime call records, remote function targets with name and
  # arity, bake nothing in, since a remote call resolves by name when
  # it runs, and never trigger a recompile; they let the server name
  # a module's callers, so remove can refuse on them and replace can
  # prove a dropped function is still called.

  @table Beamlet.Code

  @type ctx :: %{roots: MapSet.t(Path.t()), granted: MapSet.t(module())}

  @spec install(ctx()) :: [module()]
  def install(ctx) do
    :ets.insert(@table, {:ctx, ctx})
    previous = Code.get_compiler_option(:tracers)
    Code.put_compiler_option(:tracers, previous ++ [__MODULE__])
    previous
  end

  @spec uninstall([module()]) :: :ok
  def uninstall(previous) do
    Code.put_compiler_option(:tracers, previous)
    :ets.delete(@table, :ctx)
    :ok
  end

  @spec trace(tuple(), Macro.Env.t()) :: :ok
  def trace(event, env) do
    case :ets.lookup(@table, :ctx) do
      [{:ctx, ctx}] ->
        if MapSet.member?(ctx.roots, env.file), do: handle(event, env, ctx), else: :ok

      [] ->
        :ok
    end
  end

  defp handle({:remote_macro, _meta, module, _name, _arity}, env, ctx) do
    record_edge(ctx, env, module)
  end

  defp handle({:imported_function, _meta, module, _name, _arity}, env, ctx) do
    record_edge(ctx, env, module)
  end

  defp handle({:imported_macro, _meta, module, _name, _arity}, env, ctx) do
    record_edge(ctx, env, module)
  end

  defp handle({:struct_expansion, _meta, module, _keys}, env, ctx) do
    record_edge(ctx, env, module)
  end

  defp handle({:require, _meta, module, _opts}, env, ctx) do
    record_edge(ctx, env, module)
  end

  defp handle({:remote_function, _meta, module, name, arity}, env, ctx) do
    if records?(ctx, env, module) do
      :ets.insert(@table, {:call, env.module, module, name, arity})
    end

    :ok
  end

  defp handle(_event, _env, _ctx), do: :ok

  defp record_edge(ctx, env, module) do
    if records?(ctx, env, module), do: :ets.insert(@table, {:edge, env.module, module})
    :ok
  end

  defp records?(ctx, env, module) do
    env.module != nil and module != env.module and MapSet.member?(ctx.granted, module)
  end
end
