defmodule LangEx.LLM do
  @moduledoc """
  Behaviour for LLM provider adapters.

  Implement this behaviour to add support for additional LLM providers.
  """

  @type message :: %{role: String.t(), content: String.t()}

  @type chat_result :: {:ok, LangEx.Message.AI.t()} | {:error, term()}

  @doc """
  Sends a list of messages to the LLM and returns an AI response message.

  Options are provider-specific but commonly include:
  - `:api_key` - API key override
  - `:model` - model name override
  - `:temperature` - sampling temperature
  - `:max_tokens` - maximum response tokens
  """
  @callback chat([message()], keyword()) :: chat_result()
end
