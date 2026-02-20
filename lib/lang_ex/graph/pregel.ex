defmodule LangEx.Pregel do
  @moduledoc """
  Super-step execution engine inspired by Google's Pregel.

  Processes the graph in discrete super-steps: resolve which nodes to
  run next, execute them, apply state updates via reducers, then repeat
  until reaching the END node or exhausting the recursion limit.

  Supports checkpointing, interrupts, streaming events, runtime context,
  Send fan-out, and managed values (remaining_steps).
  """

  alias LangEx.Checkpoint
  alias LangEx.CompiledGraph
  alias LangEx.State
  alias LangEx.Types.Command
  alias LangEx.Types.Send

  @type run_opts :: %{
          recursion_limit: pos_integer(),
          checkpointer: module() | nil,
          config: keyword(),
          context: term(),
          resume: %{node: atom(), value: term()} | nil,
          step: non_neg_integer(),
          emit_to: pid() | nil
        }

  @doc "Runs the compiled graph from the start node through to completion."
  @spec run(CompiledGraph.t(), map(), run_opts() | pos_integer()) ::
          {:ok, map()} | {:interrupt, term(), map()} | {:error, term()}
  def run(graph, state, limit) when is_integer(limit) do
    run(graph, state, %{
      recursion_limit: limit,
      checkpointer: nil,
      config: [],
      context: nil,
      resume: nil,
      step: 0,
      emit_to: nil
    })
  end

  def run(%CompiledGraph{} = graph, state, %{resume: %{node: node, value: value}} = opts)
      when not is_nil(node) do
    Process.put(:lang_ex_resume, value)
    result = execute_single_node(graph, state, node, opts)
    Process.delete(:lang_ex_resume)

    case result do
      {:interrupted, payload, int_state} ->
        save_interrupt(graph, int_state, node, payload, opts)

      {new_state, command_targets} ->
        graph
        |> resolve_next_nodes(new_state, [node], command_targets)
        |> step(graph, new_state, %{opts | resume: nil, step: opts.step + 1})
    end
  end

  def run(%CompiledGraph{} = graph, state, opts) do
    graph
    |> resolve_targets(:__start__, state)
    |> step(graph, state, opts)
  end

  defp step([], _graph, state, _opts), do: {:ok, state}
  defp step([:__end__], _graph, state, _opts), do: {:ok, state}

  defp step(nodes, _graph, _state, %{recursion_limit: limit, step: count})
       when count >= limit do
    {:error, {:recursion_limit, count, nodes}}
  end

  defp step(active_nodes, graph, state, opts) do
    active_nodes
    |> Enum.reject(&(&1 == :__end__))
    |> run_super_step(graph, state, opts)
  end

  defp run_super_step([], _graph, state, _opts), do: {:ok, state}

  defp run_super_step(active, graph, state, opts) do
    emit(opts, {:step_start, opts.step, active})

    state
    |> inject_managed(opts)
    |> then(&execute_nodes(graph, &1, active, opts))
    |> handle_super_step_result(graph, active, opts)
  end

  defp handle_super_step_result({:interrupted, payload, int_state, node}, graph, _active, opts) do
    int_state
    |> strip_managed()
    |> then(&save_interrupt(graph, &1, node, payload, opts))
  end

  defp handle_super_step_result({new_state, command_targets}, graph, active, opts) do
    clean_state = strip_managed(new_state)
    emit(opts, {:step_end, opts.step, clean_state})
    maybe_save_checkpoint(opts, clean_state, active)

    graph
    |> resolve_next_nodes(clean_state, active, command_targets)
    |> continue(graph, clean_state, opts)
  end

  defp continue([], _graph, state, _opts), do: {:ok, state}
  defp continue([:__end__ | _], _graph, state, _opts), do: {:ok, state}

  defp continue(next, graph, state, opts),
    do: step(next, graph, state, %{opts | step: opts.step + 1})

  # --- Node execution ---

  defp execute_nodes(graph, state, [node_name], opts) do
    case execute_single_node(graph, state, node_name, opts) do
      {:interrupted, payload, int_state} -> {:interrupted, payload, int_state, node_name}
      result -> result
    end
  end

  defp execute_nodes(graph, state, nodes, opts) do
    nodes
    |> Enum.map(&spawn_node_task(graph, &1, state, opts))
    |> Task.yield_many(:infinity)
    |> Enum.reduce({state, []}, &reduce_task_result(&1, &2, graph.reducers))
  end

  defp spawn_node_task(graph, name, state, opts) do
    Task.Supervisor.async_nolink(LangEx.TaskSupervisor, fn ->
      {name, call_node(graph, name, state, opts)}
    end)
  end

  defp reduce_task_result(
         {_task, {:ok, {name, {:interrupted, payload, _}}}},
         {acc, _cmds},
         _reducers
       ) do
    {:interrupted, payload, acc, name}
  end

  defp reduce_task_result({_task, {:ok, {_name, result}}}, {acc, cmds}, reducers)
       when is_tuple(acc) do
    merge_node_result(result, acc, reducers, cmds)
  end

  defp reduce_task_result({_task, {:exit, reason}}, _acc, _reducers) do
    raise "node execution failed: #{inspect(reason)}"
  end

  defp reduce_task_result(_, {:interrupted, _, _, _} = halt, _reducers), do: halt

  defp execute_single_node(graph, state, node_name, opts) do
    emit(opts, {:node_start, node_name})

    case call_node(graph, node_name, state, opts) do
      {:interrupted, _, _} = interrupt ->
        interrupt

      result ->
        emit(opts, {:node_end, node_name, result})
        merge_node_result(result, state, graph.reducers, [])
    end
  end

  defp call_node(graph, name, state, opts) do
    fun = Map.fetch!(graph.nodes, name)

    try do
      invoke_node_fn(fun, state, opts.context)
    catch
      :throw, {:lang_ex_interrupt, payload} -> {:interrupted, payload, state}
    end
  end

  defp invoke_node_fn(fun, state, nil), do: fun.(state)

  defp invoke_node_fn(fun, state, context) do
    case Function.info(fun, :arity) do
      {:arity, 2} -> fun.(state, context)
      {:arity, 1} -> fun.(state)
    end
  end

  defp merge_node_result(%Command{update: update, goto: goto}, state, reducers, cmds) do
    {State.apply_update(state, update, reducers), cmds ++ List.wrap(goto)}
  end

  defp merge_node_result(update, state, reducers, cmds) when is_map(update) do
    {State.apply_update(state, update, reducers), cmds}
  end

  # --- Routing ---

  defp resolve_next_nodes(graph, state, executed_nodes, command_targets) do
    edge_targets = Enum.flat_map(executed_nodes, &resolve_targets(graph, &1, state))
    Enum.uniq(command_targets ++ edge_targets)
  end

  defp resolve_targets(graph, node, state) do
    fixed = Map.get(graph.edges, node, [])
    conditional = resolve_conditional(Map.fetch(graph.conditional_edges, node), state, graph)
    Enum.uniq(fixed ++ conditional)
  end

  defp resolve_conditional(:error, _state, _graph), do: []

  defp resolve_conditional({:ok, {routing_fn, mapping}}, state, graph) do
    case routing_fn.(state) do
      [%Send{} | _] = sends -> execute_sends(sends, graph)
      result -> resolve_routing_result(result, mapping)
    end
  end

  defp execute_sends(sends, graph) do
    sends
    |> Enum.map(fn %Send{node: node, state: send_state} ->
      Task.Supervisor.async_nolink(LangEx.TaskSupervisor, fn ->
        graph.nodes |> Map.fetch!(node) |> then(& &1.(send_state))
      end)
    end)
    |> Task.yield_many(:infinity)
    |> Enum.each(&validate_send_result/1)

    []
  end

  defp validate_send_result({_task, {:ok, update}}) when is_map(update), do: :ok

  defp validate_send_result({_task, {:exit, reason}}),
    do: raise("Send execution failed: #{inspect(reason)}")

  defp resolve_routing_result(result, nil) when is_atom(result), do: [result]
  defp resolve_routing_result(result, nil) when is_list(result), do: result

  defp resolve_routing_result(result, mapping) when is_map(mapping) do
    case Map.fetch(mapping, result) do
      {:ok, target} -> List.wrap(target)
      :error -> raise ArgumentError, "routing returned #{inspect(result)} but no mapping found"
    end
  end

  # --- Managed values ---

  defp inject_managed(state, %{recursion_limit: limit, step: step}) do
    Map.put(state, :remaining_steps, limit - step)
  end

  defp strip_managed(state), do: Map.delete(state, :remaining_steps)

  # --- Checkpointing ---

  defp maybe_save_checkpoint(%{checkpointer: nil}, _state, _nodes), do: :ok

  defp maybe_save_checkpoint(%{checkpointer: cp, config: config, step: step}, state, nodes) do
    config
    |> Keyword.get(:thread_id)
    |> do_save_checkpoint(cp, config,
      state: state,
      next_nodes: nodes,
      step: step,
      metadata: %{}
    )
  end

  defp do_save_checkpoint(nil, _cp, _config, _data), do: :ok

  defp do_save_checkpoint(thread_id, cp, config, data) do
    cp.save(config, Checkpoint.new([{:thread_id, thread_id} | data]))
  end

  defp save_interrupt(_graph, state, _node, payload, %{checkpointer: nil}) do
    {:interrupt, payload, state}
  end

  defp save_interrupt(_graph, state, node, payload, %{
         checkpointer: cp,
         config: config,
         step: step
       }) do
    config
    |> Keyword.get(:thread_id)
    |> do_save_interrupt(cp, config, state, node, payload, step)

    {:interrupt, payload, state}
  end

  defp do_save_interrupt(nil, _cp, _config, _state, _node, _payload, _step), do: :ok

  defp do_save_interrupt(thread_id, cp, config, state, node, payload, step) do
    cp.save(
      config,
      Checkpoint.new(
        thread_id: thread_id,
        state: state,
        next_nodes: [node],
        step: step,
        pending_interrupts: [%{value: payload, node: node}],
        metadata: %{}
      )
    )
  end

  # --- Streaming ---

  defp emit(%{emit_to: nil}, _event), do: :ok
  defp emit(%{emit_to: pid}, event), do: send(pid, {:lang_ex_stream, event})
end
