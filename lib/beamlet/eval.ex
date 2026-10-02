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
        eval: [timeout: 30_000, max_heap_bytes: 134_217_728, max_output: 32_768]

  - `timeout` (30 seconds) protects the session. An MCP session runs
    one request at a time, so a run that never ended would stall
    every request behind it. The evaluation is stopped and the output
    so far returned. The MCP request timeout (`Beamlet.Config.mcp/0`)
    must be longer, so it is never the one that fires.
  - `max_heap_bytes` (128MB) protects the beamlet: a runaway
    allocation is stopped before it takes the VM down. Binaries the
    code holds count, however large.
  - `max_output` (32KB) protects the model's context. Only the first
    32KB printed is ever held, and a longer result is cut with a line
    saying how much was shown of how much. The result or error after
    the output is kept whole when it fits, the output taking the room
    left, since that line is what the agent acts on. 32KB is under
    the point where Claude Code warns about a large tool result.
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
      |> Runner.run(principal, Keyword.take(limits, [:timeout, :max_heap_bytes, :max_output]))
      |> format(limits)
    end
  end

  defp format({:ok, %{output: output, result: result}}, limits) do
    {:ok, compose(output, "=> " <> inspect(result, @inspect_opts), limits)}
  end

  defp format({:error, :timeout, %{output: output}}, limits) do
    message =
      "Evaluation timed out after #{duration(limits[:timeout])}. " <>
        "Do less in one eval, or define a module and call it in steps."

    {:error, compose(output, message, limits)}
  end

  defp format({:error, :killed, %{output: output}}, limits) do
    message =
      "Evaluation stopped: it went over the memory limit of " <>
        "#{bytes(limits[:max_heap_bytes])}. Work on less data at a time."

    {:error, compose(output, message, limits)}
  end

  defp format({:error, {kind, reason, stacktrace}, %{output: output}}, limits) do
    {:error, compose(output, Exception.format(kind, reason, locate(stacktrace)), limits)}
  end

  # A defined module's beam records the file it was compiled from, the
  # staging copy after a define and the stored file after a boot. Its
  # frames are rewritten to the stored path relative to the code dir,
  # the one locator an agent reads everywhere, before formatting.
  defp locate(stacktrace) do
    manifest = Code.manifest()
    code_dir = Config.code_dir()

    Enum.map(stacktrace, fn
      {mod, fun, arity, location} when is_map_key(manifest, mod) and is_list(location) ->
        file = manifest |> Map.fetch!(mod) |> Map.fetch!(:source_file)
        relative = file |> Path.relative_to(code_dir) |> String.to_charlist()
        {mod, fun, arity, Keyword.put(location, :file, relative)}

      frame ->
        frame
    end)
  end

  # The tail, the result or the error, is what the agent acts on, so
  # it is kept whole when it fits and the printed output takes the
  # room left. The tail goes out JSON-encoded, and an exception's
  # message can carry any bytes, so invalid ones are replaced.
  defp compose({"", 0}, tail, limits), do: cap(String.replace_invalid(tail), limits[:max_output])

  defp compose({kept, total}, tail, limits) do
    tail = cap(String.replace_invalid(tail), limits[:max_output])
    room = max(limits[:max_output] - byte_size(tail) - 1, 0)

    if total <= room do
      kept <> "\n" <> tail
    else
      shown = cut(kept, room)
      shown <> "\n...(output " <> truncated(byte_size(shown), total) <> "\n" <> tail
    end
  end

  defp cap(text, max) when byte_size(text) <= max, do: text

  defp cap(text, max) do
    shown = cut(text, max)
    shown <> "\n...(" <> truncated(byte_size(shown), byte_size(text))
  end

  defp truncated(shown, total) do
    "truncated, showing first #{bytes(shown)} of #{bytes(total)}; print less, or filter in code)"
  end

  # The cut must not split a character, so it backs up over
  # continuation bytes to the start of the one it would.
  defp cut(text, max) when byte_size(text) <= max, do: text
  defp cut(text, max), do: binary_part(text, 0, boundary(text, max))

  defp boundary(_text, 0), do: 0

  defp boundary(text, at) do
    if :binary.at(text, at) in 0x80..0xBF, do: boundary(text, at - 1), else: at
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
