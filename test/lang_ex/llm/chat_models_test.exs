defmodule LangEx.ChatModelsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.ChatModels
  alias LangEx.Graph
  alias LangEx.Message

  describe "init_chat_model/2" do
    test "resolves OpenAI by model string" do
      assert {LangEx.LLM.OpenAI, [model: "gpt-4o"]} = ChatModels.init_chat_model("gpt-4o")
    end

    test "resolves Anthropic by model string" do
      assert {LangEx.LLM.Anthropic, [model: "claude-sonnet-4-20250514"]} =
               ChatModels.init_chat_model("claude-sonnet-4-20250514")
    end

    test "resolves Gemini by model string" do
      assert {LangEx.LLM.Gemini, [model: "gemini-2.5-flash"]} =
               ChatModels.init_chat_model("gemini-2.5-flash")
    end

    test "resolves by provider atom" do
      assert {LangEx.LLM.OpenAI, []} = ChatModels.init_chat_model(:openai)

      assert {LangEx.LLM.Anthropic, [temperature: 0.5]} =
               ChatModels.init_chat_model(:anthropic, temperature: 0.5)
    end

    test "passes through extra opts with model string" do
      assert {LangEx.LLM.OpenAI, opts} =
               ChatModels.init_chat_model("gpt-4o", temperature: 0.3, max_tokens: 512)

      assert %{model: "gpt-4o", temperature: 0.3, max_tokens: 512} = Map.new(opts)
    end

    test "raises on unknown model prefix" do
      assert_raise ArgumentError, ~r/cannot infer provider/, fn ->
        ChatModels.init_chat_model("unknown-model-xyz")
      end
    end

    test "raises on unknown provider atom" do
      assert_raise ArgumentError, ~r/unknown provider/, fn ->
        ChatModels.init_chat_model(:nonexistent)
      end
    end
  end

  describe "runtime registration" do
    test "register_provider makes a custom provider available" do
      defmodule FakeGroq do
        @behaviour LangEx.LLM
        @impl true
        def chat(_messages, _opts), do: {:ok, LangEx.Message.ai("groq response")}
      end

      ChatModels.register_provider(:groq, FakeGroq)
      assert {FakeGroq, []} = ChatModels.init_chat_model(:groq)
      assert %{groq: FakeGroq} = Map.take(ChatModels.list_providers(), [:groq])
    end

    test "register_prefix enables model-string inference for custom provider" do
      defmodule FakeOllama do
        @behaviour LangEx.LLM
        @impl true
        def chat(_messages, _opts), do: {:ok, LangEx.Message.ai("ollama response")}
      end

      ChatModels.register_provider(:ollama, FakeOllama)
      ChatModels.register_prefix("llama-", :ollama)

      assert {FakeOllama, [model: "llama-3.3-70b"]} = ChatModels.init_chat_model("llama-3.3-70b")
    end
  end

  describe "ChatModel.node with model string auto-resolution" do
    test "model string resolves provider and works in a graph" do
      stub(LangEx.LLM.OpenAI, :chat, fn _messages, _opts ->
        {:ok, Message.ai("auto-resolved response")}
      end)

      {:ok, result} =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:llm, LangEx.ChatModel.node(model: "gpt-4o"))
        |> Graph.add_edge(:__start__, :llm)
        |> Graph.add_edge(:llm, :__end__)
        |> Graph.compile()
        |> LangEx.invoke(%{messages: [Message.human("Hi")]})

      assert %{
               messages: [
                 %Message.Human{content: "Hi"},
                 %Message.AI{content: "auto-resolved response"}
               ]
             } = result
    end
  end

  describe "list_providers/0" do
    test "includes built-in providers" do
      providers = ChatModels.list_providers()

      assert %{
               openai: LangEx.LLM.OpenAI,
               anthropic: LangEx.LLM.Anthropic,
               gemini: LangEx.LLM.Gemini
             } = providers
    end
  end
end
