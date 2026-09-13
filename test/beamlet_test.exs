defmodule BeamletTest do
  use ExUnit.Case

  test "is not started as an application" do
    assert Process.whereis(Beamlet) == nil
    assert Application.spec(:beamlet, :mod) in [nil, []]
  end

  test "starts as a supervisor under the host's tree" do
    pid = start_supervised!({Beamlet, []})

    assert Process.whereis(Beamlet) == pid
    assert Supervisor.which_children(Beamlet) == []
  end
end
