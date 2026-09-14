import Config

config :beamlet, ecto_repos: [Beamlet.Repo]

config :logger, level: :warning

import_config "#{config_env()}.exs"
