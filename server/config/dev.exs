import Config

# The library's own dev data dir, so `mix beamlet` run from either
# project manages the same users and tokens.
config :beamlet, data_dir: Path.expand("../../data", __DIR__)

# Policies are read from the config the server boots with, so a
# policy for a token created with `mix beamlet` from `..` must be
# declared here as well until the operator config file arrives.
config :beamlet, policies: [explorer: [tools: [:eval]]]

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :beamlet_server, BeamletServer.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  debug_errors: true,
  secret_key_base: "+Ic/pf8QagjWd4Ig+WdnAzMx2/ezo0BVivm3Ei2dEGEh2tVSsMEMqy3GFvAcZ+ns"

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true
