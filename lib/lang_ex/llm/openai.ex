defmodule LangEx.LLM.OpenAI do
  @moduledoc """
  OpenAI chat completions adapter.

  Supports GPT-4o and other OpenAI models via the `/v1/chat/completions` endpoint.
  """

  @behaviour LangEx.LLM

  alias LangEx.Config
  alias LangEx.Message

  @base_url "https://api.openai.com/v1"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Config.api_key!(:openai, opts)
    model = Config.model(:openai, opts)

    body = %{
      model: model,
      messages: Enum.map(messages, &format_message/1),
      temperature: opts[:temperature] || 0.7,
      max_tokens: opts[:max_tokens] || 1024
    }

    with {:ok, %{status: 200, body: response}} <- do_request(api_key, body) do
      parse_response(response)
    else
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_request(api_key, body) do
    Req.post("#{@base_url}/chat/completions",
      json: body,
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]
    )
  end

  defp format_message(%Message.Human{content: c}), do: %{role: "user", content: c}
  defp format_message(%Message.AI{content: c}), do: %{role: "assistant", content: c}
  defp format_message(%Message.System{content: c}), do: %{role: "system", content: c}

  defp format_message(%Message.Tool{content: c, tool_call_id: id}),
    do: %{role: "tool", content: c, tool_call_id: id}

  defp format_message(%{role: _, content: _} = raw), do: raw

  defp parse_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    {:ok, Message.ai(content)}
  end

  defp parse_response(body), do: {:error, {:unexpected_response, body}}
end
