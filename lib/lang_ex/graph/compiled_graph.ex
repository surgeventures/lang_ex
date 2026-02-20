defmodule LangEx.CompiledGraph do
  @moduledoc """
  A compiled, executable graph.

  Created by `LangEx.Graph.compile/1`. Use `invoke/2` to run the graph
  with an initial state input.
  """

  alias LangEx.Checkpoint
  alias LangEx.Pregel
  alias LangEx.State

  defstruct [
    :nodes,
    :edges,
    :conditional_edges,
    :initial_state,
    :reducers,
    :checkpointer
  ]

  @type t :: %__MODULE__{
          nodes: %{atom() => (map() -> map())},
          edges: %{atom() => [atom()]},
          conditional_edges: %{atom() => {(map() -> atom() | String.t()), map() | nil}},
          initial_state: map(),
          reducers: State.reducers(),
          checkpointer: module() | nil
        }

  @default_recursion_limit 25

  @doc """
  Executes the compiled graph with the given input state.

  Options:
  - `:recursion_limit` - max super-steps before raising (default: #{@default_recursion_limit})
  - `:config` - keyword with `:thread_id` for checkpointing / resume
  - `:context` - runtime context passed to arity-2 node functions
  """
  @spec invoke(t(), map() | LangEx.Types.Command.t(), keyword()) ::
          {:ok, map()} | {:interrupt, term(), map()} | {:error, term()}
  def invoke(graph, input, opts \\ [])

  def invoke(
        %__MODULE__{checkpointer: cp} = graph,
        %LangEx.Types.Command{resume: resume_val},
        opts
      )
      when cp != nil and resume_val != nil do
    config = Keyword.get(opts, :config, [])

    case cp.load(config) do
      {:ok, %Checkpoint{pending_interrupts: [%{node: node} | _]} = saved} ->
        Pregel.run(
          graph,
          saved.state,
          build_run_opts(opts, graph, resume: %{node: node, value: resume_val}, step: saved.step)
        )

      _ ->
        {:error, :no_pending_interrupt}
    end
  end

  def invoke(%__MODULE__{} = graph, input, opts) when is_map(input) do
    state = resolve_initial_state(graph, input, opts)
    Pregel.run(graph, state, build_run_opts(opts, graph))
  end

  defp resolve_initial_state(graph, input, opts) do
    with cp when not is_nil(cp) <- graph.checkpointer,
         tid when not is_nil(tid) <- opts |> Keyword.get(:config, []) |> Keyword.get(:thread_id),
         {:ok, %Checkpoint{pending_interrupts: nil} = saved} <-
           cp.load(Keyword.get(opts, :config, [])) do
      saved.state
    else
      _ -> State.apply_update(graph.initial_state, input, graph.reducers)
    end
  end

  defp build_run_opts(opts, graph, overrides \\ []) do
    %{
      recursion_limit: Keyword.get(opts, :recursion_limit, @default_recursion_limit),
      checkpointer: graph.checkpointer,
      config: Keyword.get(opts, :config, []),
      context: Keyword.get(opts, :context),
      resume: Keyword.get(overrides, :resume),
      step: Keyword.get(overrides, :step, 0),
      emit_to: nil
    }
  end
end
