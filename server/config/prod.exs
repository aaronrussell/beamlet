import Config

# TLS is the proxy's job: Fly redirects to HTTPS from fly.toml, and a
# container run by hand answers plain HTTP on localhost.

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
