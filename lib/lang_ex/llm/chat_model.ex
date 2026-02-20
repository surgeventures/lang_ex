defmodule LangEx.ChatModel do
  @moduledoc """
  Helper to create graph nodes that call an LLM.

  Produces a node function that reads messages from state,
  sends them to the configured LLM provider, and appends
  the response to the messages list.
  """

  alias LangEx.ChatModels

  @doc """
  Returns a node function that calls an LLM provider.

  ## Options

  - `:provider` - module implementing `LangEx.LLM` (explicit)
  - `:model` - model string like `"gpt-4o"` or `"claude-sonnet-4-20250514"` (auto-resolves provider)
  - `:messages_key` - state key holding the message list (default: `:messages`)
  - All other opts forwarded to `provider.chat/2` (`:api_key`, `:temperature`, etc.)

  Either `:provider` or `:model` must be given. When `:model` is a string and
  `:provider` is absent, the provider is resolved via `LangEx.ChatModels.init_chat_model/2`.

  ## Examples

      Graph.add_node(:llm, ChatModel.node(provider: LangEx.LLM.OpenAI, model: "gpt-4o"))
      Graph.add_node(:llm, ChatModel.node(model: "gpt-4o"))
      Graph.add_node(:llm, ChatModel.node(model: "claude-sonnet-4-20250514", temperature: 0.3))
  """
  @spec node(keyword()) :: (map() -> map())
  def node(opts) do
    {provider, llm_opts} = resolve_provider(opts)
    {messages_key, llm_opts} = Keyword.pop(llm_opts, :messages_key, :messages)

    fn state ->
      messages = Map.fetch!(state, messages_key)
      {:ok, ai_message} = provider.chat(messages, llm_opts)
      %{messages_key => [ai_message]}
    end
  end

  defp resolve_provider(opts) do
    opts
    |> Keyword.pop(:provider)
    |> do_resolve_provider()
  end

  defp do_resolve_provider({provider, rest}) when not is_nil(provider), do: {provider, rest}

  defp do_resolve_provider({nil, rest}) do
    {model, rest} = Keyword.pop!(rest, :model)
    ChatModels.init_chat_model(model, rest)
  end
end
