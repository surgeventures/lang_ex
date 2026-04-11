defmodule LangEx.Checkpoint.InterruptTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Command

  describe "interrupts and resume" do
    test "interrupt pauses execution and resume continues it" do
      graph =
        Graph.new(value: 0, approved: false)
        |> Graph.add_node(:check, fn state ->
          approval = LangEx.Interrupt.interrupt("Approve value #{state.value}?")
          %{approved: approval}
        end)
        |> Graph.add_node(:finalize, fn state -> %{value: state.value * 10} end)
        |> Graph.add_edge(:__start__, :check)
        |> Graph.add_edge(:check, :finalize)
        |> Graph.add_edge(:finalize, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Mock)

      {:interrupt, "Approve value 42?", paused_state} =
        LangEx.invoke(graph, %{value: 42}, config: [thread_id: "test-interrupt-1"])

      assert %{value: 42, approved: false} = paused_state

      {:ok, result} =
        LangEx.invoke(graph, %Command{resume: true}, config: [thread_id: "test-interrupt-1"])

      assert %{approved: true, value: 420} = result
    end

    test "resume finds interrupt checkpoint even when later non-interrupt checkpoints exist" do
      # This tests the scenario where:
      # 1. Graph hits interrupt at node A, checkpoint saved with pending_interrupts
      # 2. Resume resolves node A, graph continues to node B, C
      # 3. Node B saves a checkpoint WITHOUT pending_interrupts (now the latest)
      # 4. Node C hits another interrupt
      # 5. A second resume call should find the interrupt from step 4,
      #    even though the latest checkpoint (from step 3) has no interrupts
      graph =
        Graph.new(value: 0, stage: "init")
        |> Graph.add_node(:first_pause, fn state ->
          result = LangEx.Interrupt.interrupt("First pause")
          %{stage: "after_first", value: state.value + result}
        end)
        |> Graph.add_node(:middle, fn state ->
          %{stage: "middle_done", value: state.value + 100}
        end)
        |> Graph.add_node(:second_pause, fn state ->
          result = LangEx.Interrupt.interrupt("Second pause")
          %{stage: "after_second", value: state.value + result}
        end)
        |> Graph.add_node(:finalize, fn state ->
          %{stage: "complete", value: state.value * 2}
        end)
        |> Graph.add_edge(:__start__, :first_pause)
        |> Graph.add_edge(:first_pause, :middle)
        |> Graph.add_edge(:middle, :second_pause)
        |> Graph.add_edge(:second_pause, :finalize)
        |> Graph.add_edge(:finalize, :__end__)
        |> Graph.compile(checkpointer: LangEx.Checkpointer.Mock)

      thread = "test-multi-interrupt-#{System.unique_integer([:positive])}"

      # First invoke hits first_pause interrupt
      {:interrupt, "First pause", _} =
        LangEx.invoke(graph, %{value: 1}, config: [thread_id: thread])

      # Resume with value 10, graph continues through middle -> second_pause interrupt
      # The middle node saves a checkpoint that becomes the latest (no interrupt)
      {:interrupt, "Second pause", state_at_second} =
        LangEx.invoke(graph, %Command{resume: 10}, config: [thread_id: thread])

      # State should reflect first_pause (1+10=11) and middle (+100=111)
      assert state_at_second.value === 111

      # Resume the second interrupt — this is the critical test.
      # The latest checkpoint is from :middle (no interrupt), but the
      # second_pause interrupt checkpoint should still be found.
      {:ok, final} =
        LangEx.invoke(graph, %Command{resume: 5}, config: [thread_id: thread])

      assert final.stage === "complete"
      assert final.value === (111 + 5) * 2
    end

    test "interrupt without checkpointer returns interrupt tuple" do
      graph =
        Graph.new(x: 0)
        |> Graph.add_node(:pause, fn _state ->
          LangEx.Interrupt.interrupt("waiting")
          %{x: 1}
        end)
        |> Graph.add_edge(:__start__, :pause)
        |> Graph.add_edge(:pause, :__end__)
        |> Graph.compile()

      assert {:interrupt, "waiting", _} = LangEx.invoke(graph, %{})
    end
  end
end
