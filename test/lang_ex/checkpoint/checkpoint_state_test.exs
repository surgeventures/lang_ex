defmodule LangEx.Checkpoint.CheckpointStateTest do
  use ExUnit.Case, async: false

  alias LangEx.Checkpointer.Mock
  alias LangEx.Graph

  setup do
    Mock.clear()
    :ok
  end

  describe "invoke with existing checkpoint merges new input" do
    test "new input overrides checkpointed values (last-write-wins)" do
      graph =
        Graph.new(value: 0, label: "")
        |> Graph.add_node(:passthrough, fn state -> %{label: "done:#{state.value}"} end)
        |> Graph.add_edge(:__start__, :passthrough)
        |> Graph.add_edge(:passthrough, :__end__)
        |> Graph.compile(checkpointer: Mock)

      {:ok, first} =
        LangEx.invoke(graph, %{value: 1}, config: [thread_id: "merge-test-1"])

      assert %{value: 1, label: "done:1"} = first

      {:ok, second} =
        LangEx.invoke(graph, %{value: 99}, config: [thread_id: "merge-test-1"])

      assert %{value: 99, label: "done:99"} = second
    end

    test "checkpointed state is preserved for keys not in new input" do
      graph =
        Graph.new(a: 0, b: 0)
        |> Graph.add_node(:sum, fn state -> %{b: state.a + state.b} end)
        |> Graph.add_edge(:__start__, :sum)
        |> Graph.add_edge(:sum, :__end__)
        |> Graph.compile(checkpointer: Mock)

      {:ok, first} =
        LangEx.invoke(graph, %{a: 10, b: 5}, config: [thread_id: "merge-test-2"])

      assert %{a: 10, b: 15} = first

      {:ok, second} =
        LangEx.invoke(graph, %{a: 20}, config: [thread_id: "merge-test-2"])

      assert %{a: 20, b: 35} = second
    end

    test "reducers are applied when merging input into checkpoint" do
      graph =
        Graph.new(log: {[], &Kernel.++/2}, step: 0)
        |> Graph.add_node(:work, fn state ->
          %{log: ["step_#{state.step}"], step: state.step + 1}
        end)
        |> Graph.add_edge(:__start__, :work)
        |> Graph.add_edge(:work, :__end__)
        |> Graph.compile(checkpointer: Mock)

      {:ok, first} =
        LangEx.invoke(graph, %{log: ["init"]}, config: [thread_id: "merge-test-3"])

      assert %{log: ["init", "step_0"], step: 1} = first

      {:ok, second} =
        LangEx.invoke(graph, %{log: ["resumed"]}, config: [thread_id: "merge-test-3"])

      assert %{log: ["init", "step_0", "resumed", "step_1"], step: 2} = second
    end

    test "fresh thread without checkpoint applies input to schema defaults" do
      graph =
        Graph.new(value: 0, label: "default")
        |> Graph.add_node(:read, fn state -> %{label: "saw:#{state.value}"} end)
        |> Graph.add_edge(:__start__, :read)
        |> Graph.add_edge(:read, :__end__)
        |> Graph.compile(checkpointer: Mock)

      {:ok, result} =
        LangEx.invoke(graph, %{value: 42}, config: [thread_id: "fresh-thread"])

      assert %{value: 42, label: "saw:42"} = result
    end

    test "without checkpointer, input always applies to schema defaults" do
      graph =
        Graph.new(value: 0)
        |> Graph.add_node(:double, fn state -> %{value: state.value * 2} end)
        |> Graph.add_edge(:__start__, :double)
        |> Graph.add_edge(:double, :__end__)
        |> Graph.compile()

      {:ok, _} = LangEx.invoke(graph, %{value: 5})
      {:ok, result} = LangEx.invoke(graph, %{value: 7})

      assert %{value: 14} = result
    end
  end
end
