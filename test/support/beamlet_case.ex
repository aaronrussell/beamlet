defmodule Beamlet.Case do
  @moduledoc """
  Test case for anything that needs a running beamlet.

  Starts one under the test supervisor against the configured
  per-run data dir and hands the path to the test as `data_dir`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Beamlet.Case
    end
  end

  setup do
    start_supervised!({Beamlet, []})
    %{data_dir: Beamlet.Config.data_dir!()}
  end
end
