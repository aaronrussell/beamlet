# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :beamlet, web: [endpoint: BeamletServer.Endpoint]

# Named time zones for agent code (DateTime.shift_zone and friends):
# tz compiles the IANA data in, so there is nothing to fetch at
# runtime. The library leaves this to the host; the server chooses.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configure the endpoint
config :beamlet_server, BeamletServer.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Beamlet.ErrorView, json: Beamlet.ErrorView],
    layout: false
  ],
  pubsub_server: Beamlet.PubSub,
  live_view: [signing_salt: "+dMmnWGa"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
