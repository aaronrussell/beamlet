import Config

config :beamlet, ecto_repos: [Beamlet.Repo]

config :logger, level: :warning

# The stylesheet for the beamlet's own pages (Beamlet.Web.Layouts),
# built from assets/css/beamlet.css into priv/static, where it is
# committed; `mix assets.build` refreshes it and precommit runs that.
config :tailwind,
  version: "4.3.3",
  beamlet: [
    args: ~w(--input=assets/css/beamlet.css --output=priv/static/beamlet.css --minify),
    cd: Path.expand("..", __DIR__)
  ]

import_config "#{config_env()}.exs"
