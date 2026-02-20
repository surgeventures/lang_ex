import Config

config :lang_ex,
  redis_url: "redis://localhost:6379"

import_config "#{config_env()}.exs"
