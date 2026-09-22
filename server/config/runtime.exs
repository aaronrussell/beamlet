import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

config :beamlet_server, BeamletServer.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # The data dir is the one thing a deployment must mount and name;
  # everything the beamlet keeps lives under it, the cookie-signing
  # secret included, so a volume carries a beamlet whole.
  data_dir =
    System.get_env("BEAMLET_DATA_DIR") ||
      raise """
      environment variable BEAMLET_DATA_DIR is missing.
      It names the directory the beamlet keeps its databases, code and files in.
      """

  unless File.dir?(data_dir) do
    raise "BEAMLET_DATA_DIR does not exist: #{data_dir} (create or mount it before starting)"
  end

  config :beamlet, data_dir: data_dir

  secret_file = Path.join(data_dir, "secret_key_base")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      case File.read(secret_file) do
        {:ok, secret} ->
          String.trim(secret)

        {:error, :enoent} ->
          secret = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
          File.write!(secret_file, secret)
          File.chmod!(secret_file, 0o600)
          secret
      end

  config :beamlet_server, BeamletServer.Endpoint,
    url: [host: "localhost", port: 4000, scheme: "http"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base,
    server: true
end

# The address the beamlet is reached at, which is what LiveView checks
# socket origins against, what Host.Router.url builds on and what every
# OAuth URL is derived from. Read in every environment, so a tunnel in
# development is one variable; production falls back to localhost.
if beamlet_url = System.get_env("BEAMLET_URL") do
  url = URI.parse(beamlet_url)

  unless url.scheme in ["http", "https"] and is_binary(url.host) and url.host != "" do
    raise """
    environment variable BEAMLET_URL must be an http or https URL with a host, \
    got: #{inspect(beamlet_url)}
    """
  end

  config :beamlet_server, BeamletServer.Endpoint,
    url: [host: url.host, port: url.port, scheme: url.scheme]
end
