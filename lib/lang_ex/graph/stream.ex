defmodule LangEx.Stream do
  @moduledoc """
  Streaming graph execution.

  Returns an Elixir `Stream` that lazily yields events as the graph
  executes. Uses a spawned process that runs Pregel and sends events
  to the consumer via the mailbox.

  ## Events

  - `{:node_start, node_name}` - a node is about to execute
  - `{:node_end, node_name, update}` - a node finished with this update
  - `{:step_start, step, active_nodes}` - a super-step begins
  - `{:step_end, step, state}` - a super-step completed
  - `{:interrupt, value}` - graph paused on interrupt
  - `{:done, result}` - graph finished with `{:ok, state}` or `{:error, ...}`
  """

  alias LangEx.CompiledGraph
  alias LangEx.Pregel
  alias LangEx.State

  @doc "Returns a lazy stream of execution events from the compiled graph."
  @spec stream(CompiledGraph.t(), map(), keyword()) :: Enumerable.t()
  def stream(%CompiledGraph{} = graph, input, opts \\ []) do
    Stream.resource(
      fn -> start_execution(graph, input, opts) end,
      &receive_events/1,
      fn _ -> :ok end
    )
  end

  defp start_execution(graph, input, opts) do
    parent = self()

    pid =
      spawn_link(fn ->
        config = Keyword.get(opts, :config, [])
        recursion_limit = Keyword.get(opts, :recursion_limit, 25)
        context = Keyword.get(opts, :context)
        cp = graph.checkpointer

        state = State.apply_update(graph.initial_state, input, graph.reducers)

        result =
          Pregel.run(graph, state, %{
            recursion_limit: recursion_limit,
            checkpointer: cp,
            config: config,
            context: context,
            resume: nil,
            step: 0,
            emit_to: parent
          })

        send(parent, {:lang_ex_stream, {:done, result}})
      end)

    pid
  end

  defp receive_events(:halted), do: {:halt, :halted}

  defp receive_events(pid) do
    receive do
      {:lang_ex_stream, {:done, result}} ->
        {[{:done, result}], :halted}

      {:lang_ex_stream, event} ->
        {[event], pid}
    after
      5_000 -> {:halt, :halted}
    end
  end
end
