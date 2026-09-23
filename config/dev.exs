import Config

config :beamlet, data_dir: Path.expand("../data", __DIR__)

config :beamlet, Beamlet.Repo,
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :beamlet, Host.Repo,
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# The operator config file, which a release reads through
# Beamlet.Config.Provider. Mix runs no config providers, so
# development imports it here; the server does the same, so the dev
# policies are declared once, in data/config.exs.
if File.exists?(file = Path.expand("../data/config.exs", __DIR__)), do: import_config(file)
