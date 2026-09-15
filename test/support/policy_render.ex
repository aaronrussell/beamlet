defmodule Beamlet.PolicyRender do
  @moduledoc false

  # Deterministic one-line-per-module rendering of a grant table, so
  # the curated default can be pinned against a committed golden file.
  # Regenerate after a deliberate curation change with:
  #
  #     MIX_ENV=test mix run --no-start -e 'File.write!(
  #       "test/support/fixtures/policy_default.txt",
  #       Beamlet.PolicyRender.render(Beamlet.Policy.Default.grants()))'
  #
  # and review the diff: the diff is the curation change.

  @spec render(Beamlet.Policy.grants()) :: String.t()
  def render(grants) do
    grants
    |> Enum.sort_by(fn {mod, _entry} -> inspect(mod) end)
    |> Enum.map_join("", fn {mod, entry} -> "#{inspect(mod)} #{render_entry(entry)}\n" end)
  end

  defp render_entry(:all), do: ":all"
  defp render_entry({:only, fas}), do: "only #{render_fas(fas)}"
  defp render_entry({:except, fas}), do: "except #{render_fas(fas)}"

  defp render_fas(fas) do
    fas
    |> Enum.sort()
    |> Enum.map_join(", ", fn {fun, arity} -> "#{fun}/#{arity}" end)
  end
end
