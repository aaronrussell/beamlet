defmodule BeamletServer.RuntimeConfigTest do
  # runtime.exs reads the environment, which is the whole VM's.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @vars ~w(BEAMLET_DATA_DIR SECRET_KEY_BASE BEAMLET_URL BEAMLET_EVAL_TIMEOUT
           BEAMLET_DEFINE_TIMEOUT BEAMLET_MCP_REQUEST_TIMEOUT BEAMLET_HTTP_ALLOW)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp read_prod, do: Config.Reader.read!(@runtime, env: :prod, target: :host)

  defp secret_key_base(config),
    do: config[:beamlet_server][BeamletServer.Endpoint][:secret_key_base]

  @tag :tmp_dir
  test "generates the cookie secret into the data dir, private, and reuses it", %{tmp_dir: dir} do
    System.put_env("BEAMLET_DATA_DIR", dir)
    secret_file = Path.join(dir, "secret_key_base")

    secret = secret_key_base(read_prod())
    assert byte_size(secret) >= 64
    assert File.read!(secret_file) == secret
    assert File.stat!(secret_file).mode |> Bitwise.band(0o777) == 0o600

    assert secret_key_base(read_prod()) == secret
  end

  @tag :tmp_dir
  test "a bad BEAMLET_URL fails with its message", %{tmp_dir: dir} do
    System.put_env("BEAMLET_DATA_DIR", dir)
    System.put_env("BEAMLET_URL", "beamlet.example.com")

    assert_raise RuntimeError, ~r/BEAMLET_URL must be an http or https URL with a host/, fn ->
      read_prod()
    end
  end

  @tag :tmp_dir
  test "a bad timeout fails with its message", %{tmp_dir: dir} do
    System.put_env("BEAMLET_DATA_DIR", dir)
    System.put_env("BEAMLET_EVAL_TIMEOUT", "30s")

    assert_raise RuntimeError,
                 ~r/BEAMLET_EVAL_TIMEOUT must be a positive whole number of milliseconds, got: "30s"/,
                 fn -> read_prod() end
  end

  @tag :tmp_dir
  test "BEAMLET_HTTP_ALLOW sets the allow list, and leaves it alone when unset", %{
    tmp_dir: dir
  } do
    System.put_env("BEAMLET_DATA_DIR", dir)
    refute read_prod()[:beamlet][:http]

    System.put_env("BEAMLET_HTTP_ALLOW", " homeassistant.local, 192.168.1.0/24,,fd00::/8 ")

    assert read_prod()[:beamlet][:http] == [
             allow: ["homeassistant.local", "192.168.1.0/24", "fd00::/8"]
           ]
  end
end
