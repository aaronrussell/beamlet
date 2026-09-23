import Config

# The library's own dev data dir, so `mix beamlet` run from either
# project manages the same users and tokens.
config :beamlet, data_dir: Path.expand("../../data", __DIR__)

# The operator config file in that data dir, which the release reads
# through Beamlet.Config.Provider. Mix runs no config providers, so
# development imports it here, as the library's own dev config does.
if File.exists?(file = Path.expand("../../data/config.exs", __DIR__)), do: import_config(file)

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

# The library is where the pages live, so development reloads it as
# well as the server: the code reloader recompiles both on a request,
# the Tailwind watcher rebuilds the stylesheet for the beamlet's own
# pages as the library's templates change (the build is the
# library's, `mix tailwind beamlet` from `..`, so the server declares
# no Tailwind config of its own), and live reload watches the
# library's directory beside the server's, by absolute path since
# the watcher's default is the server's root alone.
library_dir = Path.expand("../..", __DIR__)

config :beamlet_server, BeamletServer.Endpoint,
  code_reloader: true,
  reloadable_apps: [:beamlet, :beamlet_server],
  watchers: [
    mix: ["tailwind", "beamlet", "--watch", cd: library_dir]
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/beamlet\.css$",
      ~r"lib/beamlet/.*(ex|heex)$",
      ~r"lib/beamlet_server/.*(ex|heex)$"
    ]
  ]

config :phoenix_live_reload, :dirs, [Path.expand("..", __DIR__), library_dir]
