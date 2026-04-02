defmodule LangExTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Message

  test "end-to-end: classify-and-respond agent with conditional routing" do
    classify_content = fn
      "weather" -> "weather"
      "hello" -> "greeting"
      _ -> "unknown"
    end

    classifier = fn state ->
      content = List.last(state.messages).content

      intent =
        ["weather", "hello"]
        |> Enum.find(&String.contains?(content, &1))
        |> classify_content.()

      %{intent: intent}
    end

    {:ok, result} =
      Graph.new(
        messages: {[], &Message.add_messages/2},
        intent: nil,
        response: nil
      )
      |> Graph.add_node(:classify, classifier)
      |> Graph.add_node(:weather, fn _s -> %{response: "It's sunny today!"} end)
      |> Graph.add_node(:greet, fn _s -> %{response: "Hey there!"} end)
      |> Graph.add_node(:fallback, fn _s -> %{response: "I don't understand."} end)
      |> Graph.add_edge(:__start__, :classify)
      |> Graph.add_conditional_edges(:classify, &Map.get(&1, :intent), %{
        "weather" => :weather,
        "greeting" => :greet,
        "unknown" => :fallback
      })
      |> Graph.add_edge(:weather, :__end__)
      |> Graph.add_edge(:greet, :__end__)
      |> Graph.add_edge(:fallback, :__end__)
      |> Graph.compile()
      |> LangEx.invoke(%{messages: [Message.human("What's the weather?")]})

    assert %{
             intent: "weather",
             response: "It's sunny today!",
             messages: [%Message.Human{content: "What's the weather?"}]
           } = result
  end
end
