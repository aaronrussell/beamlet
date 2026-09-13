defmodule BeamletTest do
  use Beamlet.Case

  test "runs as a supervisor under the host's tree", %{data_dir: data_dir} do
    assert Process.whereis(Beamlet) != nil
    assert Supervisor.which_children(Beamlet) == []
    assert File.dir?(data_dir)
  end
end

defmodule BeamletNotStartedTest do
  use ExUnit.Case

  test "is not started as an application" do
    assert Process.whereis(Beamlet) == nil
    assert Application.spec(:beamlet, :mod) in [nil, []]
  end
end
