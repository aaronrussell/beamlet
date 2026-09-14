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
