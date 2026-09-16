defmodule Beamlet.ConfigTest do
  use ExUnit.Case, async: false
  alias Beamlet.Config

  setup do
    previous = Application.fetch_env!(:beamlet, :data_dir)

    on_exit(fn ->
      Application.put_env(:beamlet, :data_dir, previous)
      Application.delete_env(:beamlet, :policies)
      Application.delete_env(:beamlet, :eval)
    end)

    %{configured: previous}
  end

  describe "validate!/0" do
    test "passes the test config" do
      assert :ok = Config.validate!()
    end

    test "raises when the data dir is unset" do
      Application.delete_env(:beamlet, :data_dir)

      assert_raise ArgumentError, ~r/:data_dir is not set/, fn -> Config.validate!() end
    end

    test "raises when the data dir is relative" do
      Application.put_env(:beamlet, :data_dir, "data")

      assert_raise ArgumentError, ~r/must be absolute, got: data/, fn -> Config.validate!() end
    end

    test "raises when the data dir is not a string" do
      Application.put_env(:beamlet, :data_dir, :data)

      assert_raise ArgumentError, ~r/must be a path string, got: :data/, fn ->
        Config.validate!()
      end
    end

    test "raises when the policies are not a keyword list" do
      Application.put_env(:beamlet, :policies, %{explorer: []})

      assert_raise ArgumentError, ~r/:policies must be a keyword list/, fn ->
        Config.validate!()
      end
    end

    test "raises when the eval limits are not a keyword list" do
      Application.put_env(:beamlet, :eval, %{timeout: 100})

      assert_raise ArgumentError, ~r/must be a keyword list of limits/, fn ->
        Config.validate!()
      end
    end

    test "raises on an unknown eval limit" do
      Application.put_env(:beamlet, :eval, timeouts: 100)

      assert_raise ArgumentError, ~r/got: {:timeouts, 100}/, fn -> Config.validate!() end
    end

    test "raises on an eval limit that is not a positive integer" do
      Application.put_env(:beamlet, :eval, timeout: "100")

      assert_raise ArgumentError, ~r/each a positive integer/, fn -> Config.validate!() end
    end

    @tag :capture_log
    test "a bad key fails the boot" do
      Application.put_env(:beamlet, :data_dir, "data")

      assert {:error, {{%ArgumentError{message: message}, _stack}, _spec}} =
               start_supervised({Beamlet, []})

      assert message =~ "must be absolute"
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

  describe "the accessors" do
    test "data_dir/0 is the configured path", %{configured: configured} do
      assert Config.data_dir() == configured
    end

    test "db_dir/0 is the db directory under the data dir", %{configured: configured} do
      assert Config.db_dir() == Path.join(configured, "db")
    end

    test "policies/0 is empty when unset" do
      assert Config.policies() == []
    end

    test "eval/0 is the defaults when unset" do
      assert Config.eval() == [timeout: 30_000, max_heap_bytes: 268_435_456, max_output: 16_384]
    end

    test "eval/0 merges a configured limit over the defaults" do
      Application.put_env(:beamlet, :eval, timeout: 100)

      assert Config.eval() == [timeout: 100, max_heap_bytes: 268_435_456, max_output: 16_384]
    end
  end
end
