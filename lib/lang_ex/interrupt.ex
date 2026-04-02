defmodule LangEx.Interrupt do
  @moduledoc """
  Pause graph execution and wait for external input.

  Call `interrupt/1` inside any node function. If a resume value
  has been provided (via `Command(resume: value)`), it is returned
  immediately. Otherwise execution is paused and the payload is
  surfaced to the caller.
  """

  @doc """
  Pauses graph execution with the given payload.

  Returns the resume value when the graph is resumed via
  `LangEx.invoke(graph, %Command{resume: value}, config: ...)`.
  """
  @spec interrupt(term()) :: term()
  def interrupt(payload \\ nil) do
    :lang_ex_resume
    |> Process.get()
    |> resolve_resume(payload)
  end

  defp resolve_resume(nil, payload), do: throw({:lang_ex_interrupt, payload})
  defp resolve_resume(value, _payload), do: value
end
