defmodule Beamlet.Eval do
  @moduledoc """
  Evaluate Elixir code on your beamlet: the runtime behind the `eval`
  tool.

  Each run is a fresh evaluation inside the beamlet's own VM, with
  empty bindings and no prelude, so the code can call everything the
  beamlet has, every module defined on it included, and nothing
  carries over from one run to the next. The code is scanned against
  the principal's policy first (`Beamlet.Scanner`), with the defined
  modules granted by existence, then evaluated in a process of its
  own with its output captured, as that principal
  (`Beamlet.Principal.current/0`).

  The result is text: whatever the code printed, then `=> ` and the
  inspected value of the last expression. Anything that goes wrong is
  text too, a refused call, a raised exception, a timeout, and keeps
  the output printed before it, so the agent's loop is write, run,
  read, fix.

      {:ok, "hi\\n=> :ok"} = Beamlet.Eval.run(~s|IO.puts("hi")|, principal)
      {:error, "** (ArithmeticError) bad argument" <> _} = Beamlet.Eval.run("1 / 0", principal)

  ## Limits

  Three limits, set in config, each protecting one thing:

      config :beamlet,
        eval: [timeout: 30_000, max_heap_bytes: 268_435_456, max_output: 16_384]

  - `timeout` (30 seconds) protects the session. An MCP session runs
    one request at a time, so a run that never ended would stall
    every request behind it. The evaluation is stopped and the output
    so far returned. The MCP transport's own request timeout is set
    from this one plus a margin, so it is never the one that fires.
  - `max_heap_bytes` (256MB) protects the beamlet: a runaway
    allocation is stopped before it takes the VM down.
  - `max_output` (16KB) protects the model's context. A longer result
    is cut with a line saying how much was shown of how much. 16KB
    is around four to five thousand tokens of inspected Elixir, under
    the point where clients start warning about large tool results.
  """

  alias Beamlet.Code
  alias Beamlet.Config
  alias Beamlet.Eval.Runner
  alias Beamlet.Policies
  alias Beamlet.Policy
  alias Beamlet.Principal
  alias Beamlet.Scanner

  @inspect_opts [pretty: true, limit: 50, printable_limit: 4_096]

  @doc """
  Scans and evaluates `code` as `principal`, returning the result text
  or the error text.

  `opts` override the configured limits for this run.
  """
  @spec run(String.t(), Principal.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(code, %Principal{} = principal, opts \\ []) when is_binary(code) do
    {:ok, policy} = Policies.fetch(principal.policy)
    policy = Policy.grant(policy, Code.defined())
    limits = Keyword.merge(Config.eval(), opts)

    with :ok <- Scanner.scan_eval(code, policy) do
      code
      |> Runner.run(principal, Keyword.take(limits, [:timeout, :max_heap_bytes]))
      |> format(limits)
    end
  end

  defp format({:ok, %{output: output, result: result}}, limits) do
    {:ok, cap(join(output, "=> " <> inspect(result, @inspect_opts)), limits)}
  end

  defp format({:error, :timeout, %{output: output}}, limits) do
    message =
      "Evaluation timed out after #{duration(limits[:timeout])}. " <>
        "Do less in one eval, or define a module and call it in steps."

    {:error, cap(join(output, message), limits)}
  end

  defp format({:error, :killed, %{output: output}}, limits) do
    message =
      "Evaluation stopped: it went over the memory limit of " <>
        "#{bytes(limits[:max_heap_bytes])}. Work on less data at a time."

    {:error, cap(join(output, message), limits)}
  end

  defp format({:error, {kind, reason, stacktrace}, %{output: output}}, limits) do
    {:error, cap(join(output, Exception.format(kind, reason, stacktrace)), limits)}
  end

  defp join("", text), do: text
  defp join(output, text), do: output <> "\n" <> text

  defp cap(text, limits) do
    max = limits[:max_output]

    if byte_size(text) <= max do
      text
    else
      cut(text, max) <>
        "\n...(truncated, showing first #{bytes(max)} of #{bytes(byte_size(text))}; " <>
        "print less, or filter in code)"
    end
  end

  # The result is JSON-encoded on its way out, so the cut must not
  # split a character.
  defp cut(text, max) do
    part = binary_part(text, 0, max)
    if String.valid?(part), do: part, else: cut(text, max - 1)
  end

  defp duration(ms) when rem(ms, 1_000) == 0, do: "#{div(ms, 1_000)}s"
  defp duration(ms), do: "#{ms}ms"

  defp bytes(n) when n < 1_024, do: "#{n}B"
  defp bytes(n) when n < 1_048_576, do: "#{round_unit(n / 1_024)}KB"
  defp bytes(n), do: "#{round_unit(n / 1_048_576)}MB"

  defp round_unit(x) do
    case Float.round(x, 1) do
      whole when whole == trunc(whole) -> trunc(whole)
      fraction -> fraction
    end
  end
end
