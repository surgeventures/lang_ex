defmodule SupportTriage.Repo do
  use Ecto.Repo,
    otp_app: :support_triage,
    adapter: Ecto.Adapters.Postgres
end
