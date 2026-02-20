defmodule LangEx.MessageTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Message

  describe "message construction and reducer" do
    test "creates typed messages and add_messages appends them" do
      initial = [Message.system("You are a bot"), Message.human("Hi")]
      reply = Message.ai("Hello!")

      result = Message.add_messages(initial, [reply])

      assert [
               %Message.System{content: "You are a bot"},
               %Message.Human{content: "Hi"},
               %Message.AI{content: "Hello!"}
             ] = result
    end

    test "add_messages replaces messages with matching IDs" do
      original = [
        Message.human("Draft 1", id: "msg-1"),
        Message.ai("Response", id: "msg-2")
      ]

      correction = [Message.human("Draft 2", id: "msg-1")]

      result = Message.add_messages(original, correction)

      assert [
               %Message.Human{content: "Draft 2", id: "msg-1"},
               %Message.AI{content: "Response", id: "msg-2"}
             ] = result
    end

    test "add_messages appends new messages with IDs not in existing" do
      existing = [Message.human("Hi")]
      new_with_id = [Message.ai("Hello!", id: "fresh-1")]

      result = Message.add_messages(existing, new_with_id)

      assert [
               %Message.Human{content: "Hi"},
               %Message.AI{content: "Hello!", id: "fresh-1"}
             ] = result
    end

    test "message reducer works within a graph pipeline" do
      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:greet, fn _state ->
          %{messages: [Message.ai("Hello there!")]}
        end)
        |> Graph.add_edge(:__start__, :greet)
        |> Graph.add_edge(:greet, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hi")]})

      assert %{
               messages: [
                 %Message.Human{content: "Hi"},
                 %Message.AI{content: "Hello there!"}
               ]
             } = result
    end
  end
end
