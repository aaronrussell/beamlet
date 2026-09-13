defmodule BeamletTest do
  use ExUnit.Case
  doctest Beamlet

  test "greets the world" do
    assert Beamlet.hello() == :world
  end
end
