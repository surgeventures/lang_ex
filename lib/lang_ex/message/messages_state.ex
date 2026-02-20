defmodule LangEx.MessagesState do
  @moduledoc """
  Pre-built state schema with a `messages` key using the `add_messages` reducer.

  ## Example

      Graph.new(LangEx.MessagesState.schema(intent: nil, response: nil))
  """

  alias LangEx.Message

  @doc "Returns a schema keyword list with `messages` and any extra keys."
  @spec schema(keyword()) :: keyword()
  def schema(extra \\ []) do
    [{:messages, {[], &Message.add_messages/2}} | extra]
  end
end
