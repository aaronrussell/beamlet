import Config

# The application starts before any test helper runs, and a beamlet
# refuses to boot into a data dir that does not exist.
data_dir = Path.expand("../tmp/test_data", __DIR__)
File.mkdir_p!(data_dir)
config :beamlet, data_dir: data_dir

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :beamlet_server, BeamletServer.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "MlF/6On53xapfmJrix+kMBxtZADNYGSMXtASqdk4vJY3MtLIHD4AMjZqBXrccXKl",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
