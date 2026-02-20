defmodule LangEx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Task.Supervisor, name: LangEx.TaskSupervisor}
      ] ++ redix_child()

    Supervisor.start_link(children, strategy: :one_for_one, name: LangEx.Supervisor)
  end

  defp redix_child do
    if Code.ensure_loaded?(Redix) do
      redis_url = Application.get_env(:lang_ex, :redis_url, "redis://localhost:6379")
      [Redix.child_spec({redis_url, name: LangEx.Redix})]
    else
      []
    end
  end
end
