import Config

config :incident_responder,
  ecto_repos: [IncidentResponder.Repo]

config :incident_responder, IncidentResponder.Repo,
  username: "lang_ex",
  password: "lang_ex",
  hostname: "localhost",
  database: "incident_responder_#{config_env()}",
  pool_size: 5

if config_env() == :test do
  config :incident_responder, IncidentResponder.Repo,
    pool: Ecto.Adapters.SQL.Sandbox
end

import_config "runtime.exs"
