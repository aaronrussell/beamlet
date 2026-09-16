defmodule Beamlet.ConfigTest do
  use ExUnit.Case, async: false
  alias Beamlet.Config

  setup do
    previous = Application.fetch_env!(:beamlet, :data_dir)
    on_exit(fn -> Application.put_env(:beamlet, :data_dir, previous) end)
    %{configured: previous}
  end

  describe "data_dir!/0" do
    test "returns the configured absolute path", %{configured: configured} do
      assert Config.data_dir!() == configured
    end

    test "raises when unset" do
      Application.delete_env(:beamlet, :data_dir)

      assert_raise ArgumentError, ~r/:data_dir is not set/, fn -> Config.data_dir!() end
    end

    test "raises when relative" do
      Application.put_env(:beamlet, :data_dir, "data")

      assert_raise ArgumentError, ~r/must be absolute, got: data/, fn -> Config.data_dir!() end
    end

    test "raises when not a string" do
      Application.put_env(:beamlet, :data_dir, :data)

      assert_raise ArgumentError, ~r/must be a path string, got: :data/, fn ->
        Config.data_dir!()
      end
    end

    @tag :capture_log
    test "starting fails when the data dir does not exist" do
      missing =
        Path.join(System.tmp_dir!(), "beamlet_missing_#{System.unique_integer([:positive])}")

      Application.put_env(:beamlet, :data_dir, missing)

      assert {:error, {{%ArgumentError{message: message}, _stack}, _spec}} =
               start_supervised({Beamlet, []})

      assert message =~ "does not exist: #{missing}"
    end
  end

  describe "db_dir/0" do
    test "is the db directory under the data dir", %{configured: configured} do
      assert Config.db_dir() == Path.join(configured, "db")
    end
  end

  describe "eval!/0" do
    setup do
      on_exit(fn -> Application.delete_env(:beamlet, :eval) end)
    end

    test "is the defaults when unset" do
      assert Config.eval!() == [timeout: 30_000, max_heap_bytes: 268_435_456, max_output: 16_384]
    end

    test "merges a configured limit over the defaults" do
      Application.put_env(:beamlet, :eval, timeout: 100)

      assert Config.eval!() == [timeout: 100, max_heap_bytes: 268_435_456, max_output: 16_384]
    end

    test "raises when not a keyword list" do
      Application.put_env(:beamlet, :eval, %{timeout: 100})

      assert_raise ArgumentError, ~r/must be a keyword list of limits/, fn -> Config.eval!() end
    end

    test "raises on an unknown limit" do
      Application.put_env(:beamlet, :eval, timeouts: 100)

      assert_raise ArgumentError, ~r/got: {:timeouts, 100}/, fn -> Config.eval!() end
    end

    test "raises on a limit that is not a positive integer" do
      Application.put_env(:beamlet, :eval, timeout: "100")

      assert_raise ArgumentError, ~r/each a positive integer/, fn -> Config.eval!() end
    end
  end
end
