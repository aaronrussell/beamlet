defmodule Beamlet.Config.ProviderTest do
  use ExUnit.Case, async: true

  alias Beamlet.Config.Provider

  # Each test gets a directory of its own under the run's data dir,
  # since the provider reads a path and touches no application env.
  setup %{test: test} do
    dir = Path.join([Beamlet.Config.data_dir(), "provider", Atom.to_string(test)])
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    %{dir: dir, config_file: Path.join(dir, "config.exs")}
  end

  describe "init/1" do
    test "keeps a path, plain or from the environment" do
      assert Provider.init(path: "/data/config.exs") == "/data/config.exs"

      assert Provider.init(path: {:system, "BEAMLET_DATA_DIR", "/config.exs"}) ==
               {:system, "BEAMLET_DATA_DIR", "/config.exs"}
    end

    test "requires a path of the shape Config.Provider accepts" do
      assert_raise KeyError, fn -> Provider.init([]) end
      assert_raise ArgumentError, fn -> Provider.init(path: :data) end
    end
  end

  describe "load/2" do
    test "returns the config unchanged when there is no file", %{config_file: file} do
      config = [beamlet: [policies: [explorer: [tools: [:eval]]]]]
      assert Provider.load(config, file) == config
    end

    test "merges what the file declares over the config", %{config_file: file} do
      File.write!(file, """
      import Config

      config :beamlet,
        policies: [explorer: [tools: [:eval]]],
        eval: [max_output: 100]
      """)

      config = [
        beamlet: [policies: [reader: [tools: []]], eval: [timeout: 1]],
        logger: [level: :info]
      ]

      merged = Provider.load(config, file)

      assert Enum.sort(Keyword.keys(merged)) == [:beamlet, :logger]
      assert merged[:logger] == [level: :info]

      assert merged[:beamlet] == [
               policies: [reader: [tools: []], explorer: [tools: [:eval]]],
               eval: [timeout: 1, max_output: 100]
             ]
    end

    test "the file wins on a key both declare", %{config_file: file} do
      File.write!(file, """
      import Config
      config :beamlet, policies: [explorer: [tools: [:eval, :define]]]
      """)

      config = [beamlet: [policies: [explorer: [tools: [:eval]]]]]

      assert Provider.load(config, file) == [
               beamlet: [policies: [explorer: [tools: [:eval, :define]]]]
             ]
    end

    test "resolves a path from an environment variable", %{dir: dir, config_file: file} do
      File.write!(file, "import Config\nconfig :beamlet, eval: [timeout: 5]\n")
      variable = "BEAMLET_PROVIDER_TEST_#{System.unique_integer([:positive])}"
      System.put_env(variable, dir)
      on_exit(fn -> System.delete_env(variable) end)

      assert Provider.load([], {:system, variable, "/config.exs"}) == [
               beamlet: [eval: [timeout: 5]]
             ]
    end

    test "names the file and line of a syntax error", %{config_file: file} do
      File.write!(file, """
      import Config

      config :beamlet, policies: [explorer: [tools: [:eval]]
      """)

      error = assert_raise ArgumentError, fn -> Provider.load([], file) end
      assert error.message =~ "#{file}:3:"
    end

    test "names the file and line of an error raised while evaluating", %{config_file: file} do
      File.write!(file, """
      import Config
      config :beamlet, policies: undeclared()
      """)

      error = assert_raise ArgumentError, fn -> Provider.load([], file) end
      assert error.message =~ "#{file}:2:"
      assert error.message =~ "undeclared"
    end

    test "names the file when the error has no line", %{config_file: file} do
      File.write!(file, "[1, 2, 3]\n")

      error = assert_raise ArgumentError, fn -> Provider.load([], file) end
      assert error.message =~ "#{file}: "
    end
  end
end
