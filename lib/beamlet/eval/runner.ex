defmodule Beamlet.Eval.Runner do
  @moduledoc false

  # The code runs in a process of its own so that the timeout and the
  # heap cap can kill it while the caller survives to report, with the
  # output so far; the caller owns the StringIO for the same reason.
  # The child is not linked, since those two kills would take the
  # caller down with it. A cancel from the client kills the caller
  # instead (Anubis terminates the tool task), and nothing would tell
  # the child, so a watcher monitors the caller and kills the child
  # when it goes: the one-way tie Erlang has no primitive for.

  alias Beamlet.Principal

  @type outcome ::
          {:ok, %{output: String.t(), result: term()}}
          | {:error, :timeout | :killed | {atom(), term(), Exception.stacktrace()},
             %{output: String.t()}}

  @spec run(String.t(), Principal.t(), keyword()) :: outcome()
  def run(code, %Principal{} = principal, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    heap_words = div(Keyword.fetch!(opts, :max_heap_bytes), :erlang.system_info(:wordsize))
    {:ok, io} = StringIO.open("")

    task =
      Task.Supervisor.async_nolink(Beamlet.TaskSupervisor, fn ->
        Process.group_leader(self(), io)
        Process.flag(:max_heap_size, %{size: heap_words, kill: true, error_logger: false})
        Principal.put_current(principal)
        evaluate(code)
      end)

    watch(self(), task.pid)

    outcome = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)
    {_input, output} = StringIO.contents(io)
    StringIO.close(io)

    case outcome do
      {:ok, {:ok, result}} ->
        {:ok, %{output: output, result: result}}

      {:ok, {:caught, kind, reason, stacktrace}} ->
        {:error, {kind, reason, stacktrace}, %{output: output}}

      {:exit, :killed} ->
        {:error, :killed, %{output: output}}

      {:exit, reason} ->
        {:error, {:exit, reason, []}, %{output: output}}

      nil ->
        {:error, :timeout, %{output: output}}
    end
  end

  defp watch(caller, child) do
    spawn(fn ->
      caller_ref = Process.monitor(caller)
      child_ref = Process.monitor(child)

      receive do
        {:DOWN, ^caller_ref, :process, _pid, _reason} -> Process.exit(child, :kill)
        {:DOWN, ^child_ref, :process, _pid, _reason} -> :ok
      end
    end)
  end

  # A compile error raised by eval says only that errors have been
  # logged; the message itself is in the diagnostics, which the agent
  # never sees unless it is carried into the error.
  defp evaluate(code) do
    {outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {result, _bindings} = Code.eval_string(code)
          {:ok, result}
        catch
          kind, reason -> {:caught, kind, reason, __STACKTRACE__}
        end
      end)

    with_diagnostics(outcome, diagnostics)
  end

  defp with_diagnostics({:caught, :error, %CompileError{} = error, stacktrace}, diagnostics) do
    case for %{severity: :error} = diagnostic <- diagnostics, do: diagnostic do
      [] ->
        {:caught, :error, error, stacktrace}

      errors ->
        description = Enum.map_join(errors, "\n", &"line #{line(&1)}: #{&1.message}")
        {:caught, :error, %{error | file: nil, line: 0, description: description}, stacktrace}
    end
  end

  defp with_diagnostics(outcome, _diagnostics), do: outcome

  defp line(%{position: {line, _column}}), do: line
  defp line(%{position: line}) when is_integer(line), do: line
  defp line(_diagnostic), do: 0
end
