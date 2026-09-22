import Config

# Wiped and recreated by test_helper.exs at the start of every run, so
# no run sees a previous run's state and the last run stays
# inspectable
config :beamlet, data_dir: Path.expand("../tmp/test_data", __DIR__)

config :beamlet, Beamlet.Repo,
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :beamlet, Host.Repo,
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :beamlet, web: [endpoint: Beamlet.TestEndpoint]

config :beamlet, Beamlet.TestEndpoint,
  url: [host: "localhost", port: 4000],
  secret_key_base: "beamlet-test-secret-key-base-that-is-long-enough-for-phoenix-to-accept-it",
  live_view: [signing_salt: "beamlet-test-lv"],
  pubsub_server: Beamlet.PubSub,
  render_errors: [
    formats: [html: Beamlet.Web.ErrorView, json: Beamlet.Web.ErrorView],
    layout: false
  ],
  server: false

config :pbkdf2_elixir, rounds: 1

# The client-document fetch goes to a Req.Test stub, and the address
# check to a resolver that never touches DNS (Beamlet.TestResolver).
config :beamlet, Beamlet.OAuth.Clients,
  req_options: [
    plug: {Req.Test, Beamlet.OAuth.Clients},
    ssrf_check: [resolver: &Beamlet.TestResolver.resolve/3]
  ]
