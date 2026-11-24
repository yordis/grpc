import Config

# stdout carries the runner handshake bytes, so all logs go to stderr.
config :logger, :default_handler, config: %{type: :standard_error}
config :logger, level: :warning
