import Config

config :support_triage,
  ecto_repos: [SupportTriage.Repo]

config :support_triage, SupportTriage.Repo,
  username: "lang_ex",
  password: "lang_ex",
  hostname: "localhost",
  database: "support_triage_#{config_env()}",
  pool_size: 5

if config_env() == :test do
  config :support_triage, SupportTriage.Repo,
    pool: Ecto.Adapters.SQL.Sandbox
end
