defmodule IncidentResponder.Repo do
  use Ecto.Repo,
    otp_app: :incident_responder,
    adapter: Ecto.Adapters.Postgres
end
