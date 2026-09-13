import Config

# Wiped and recreated by test_helper.exs at the start of every run, so
# no run sees a previous run's state and the last run stays
# inspectable
config :beamlet, data_dir: Path.expand("../tmp/test_data", __DIR__)
