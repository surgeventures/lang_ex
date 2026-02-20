defmodule SupportTriage.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SupportTriage.Repo
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SupportTriage.Supervisor)
  end
end
