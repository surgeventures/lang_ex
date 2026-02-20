defmodule LangEx.Features.SequenceTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Message
  alias LangEx.MessagesState

  describe "add_sequence" do
    test "chains nodes with sequential edges" do
      {:ok, result} =
        Graph.new(log: {[], &Kernel.++/2})
        |> Graph.add_node(:a, fn _state -> %{log: ["a"]} end)
        |> Graph.add_node(:b, fn _state -> %{log: ["b"]} end)
        |> Graph.add_node(:c, fn _state -> %{log: ["c"]} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_sequence([:a, :b, :c])
        |> Graph.add_edge(:c, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{})

      assert %{log: ["a", "b", "c"]} = result
    end
  end

  describe "MessagesState" do
    test "provides pre-built schema with messages reducer" do
      {:ok, result} =
        Graph.new(MessagesState.schema(intent: nil))
        |> Graph.add_node(:reply, fn _state ->
          %{messages: [Message.ai("Hi!")], intent: "greeting"}
        end)
        |> Graph.add_edge(:__start__, :reply)
        |> Graph.add_edge(:reply, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hello")]})

      assert %{
               intent: "greeting",
               messages: [
                 %Message.Human{content: "Hello"},
                 %Message.AI{content: "Hi!"}
               ]
             } = result
    end
  end
end
