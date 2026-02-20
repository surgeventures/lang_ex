defmodule LangEx.Checkpoint.InterruptTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Types.Command

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
