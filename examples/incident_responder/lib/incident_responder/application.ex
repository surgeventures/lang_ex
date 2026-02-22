defmodule IncidentResponder.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      IncidentResponder.Repo
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: IncidentResponder.Supervisor)
  end
end
