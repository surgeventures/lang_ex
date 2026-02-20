defmodule LangEx.ChatModelTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.ChatModel
  alias LangEx.Graph
  alias LangEx.Message

  describe "ChatModel node with mocked LLM" do
    test "OpenAI-backed node appends AI response to message history" do
      stub(LangEx.LLM.OpenAI, :chat, fn _messages, _opts ->
        {:ok, Message.ai("I'm GPT, nice to meet you!")}
      end)

      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, ChatModel.node(provider: LangEx.LLM.OpenAI, model: "gpt-4o"))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hello GPT")]})

      assert %{
               messages: [
                 %Message.Human{content: "Hello GPT"},
                 %Message.AI{content: "I'm GPT, nice to meet you!"}
               ]
             } = result
    end

    test "Anthropic-backed node appends AI response to message history" do
      stub(LangEx.LLM.Anthropic, :chat, fn _messages, _opts ->
        {:ok, Message.ai("I'm Claude, happy to help!")}
      end)

      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, ChatModel.node(provider: LangEx.LLM.Anthropic))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{
          messages: [Message.system("Be helpful"), Message.human("Hello Claude")]
        })

      assert %{
               messages: [
                 %Message.System{content: "Be helpful"},
                 %Message.Human{content: "Hello Claude"},
                 %Message.AI{content: "I'm Claude, happy to help!"}
               ]
             } = result
    end

    test "Gemini-backed node appends AI response to message history" do
      stub(LangEx.LLM.Gemini, :chat, fn _messages, _opts ->
        {:ok, Message.ai("I'm Gemini, ready to help!")}
      end)

      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, ChatModel.node(model: "gemini-2.5-flash"))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hello Gemini")]})

      assert %{
               messages: [
                 %Message.Human{content: "Hello Gemini"},
                 %Message.AI{content: "I'm Gemini, ready to help!"}
               ]
             } = result
    end

    test "multi-turn conversation with LLM node in a loop" do
      call_count = :counters.new(1, [:atomics])

      stub(LangEx.LLM.OpenAI, :chat, fn _messages, _opts ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)
        {:ok, Message.ai("Response #{n}")}
      end)

      {:ok, result} =
        Graph.new(
          messages: {[], &Message.add_messages/2},
          turns: {0, fn _old, new -> new end}
        )
        |> Graph.add_node(:llm, fn state ->
          {:ok, ai_msg} = LangEx.LLM.OpenAI.chat(state.messages, [])
          %{messages: [ai_msg], turns: state.turns + 1}
        end)
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_conditional_edges(:llm, fn
          %{turns: t} when t >= 3 -> :__end__
          _ -> :llm
        end)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Start")]})

      assert %{
               turns: 3,
               messages: [
                 %Message.Human{content: "Start"},
                 %Message.AI{content: "Response 1"},
                 %Message.AI{content: "Response 2"},
                 %Message.AI{content: "Response 3"}
               ]
             } = result
    end
  end
end
