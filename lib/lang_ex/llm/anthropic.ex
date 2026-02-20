defmodule LangEx.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude chat adapter.

  Supports Claude Sonnet, Opus, and Haiku models via the `/v1/messages` endpoint.
  """

  @behaviour LangEx.LLM

  alias LangEx.Config
  alias LangEx.Message

  @base_url "https://api.anthropic.com/v1"
  @api_version "2023-06-01"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Config.api_key!(:anthropic, opts)
    model = Config.model(:anthropic, opts)

    {system_prompt, conversation} = extract_system(messages)

    body =
      %{
        model: model,
        messages: Enum.map(conversation, &format_message/1),
        max_tokens: opts[:max_tokens] || 1024,
        temperature: opts[:temperature] || 0.7
      }
      |> put_system(system_prompt)

    with {:ok, %{status: 200, body: response}} <- do_request(api_key, body) do
      parse_response(response)
    else
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_request(api_key, body) do
    Req.post("#{@base_url}/messages",
      json: body,
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", @api_version},
        {"content-type", "application/json"}
      ]
    )
  end

  defp extract_system(messages) do
    {system_msgs, rest} = Enum.split_with(messages, &match?(%Message.System{}, &1))
    {join_system(system_msgs), rest}
  end

  defp join_system([]), do: nil
  defp join_system(msgs), do: Enum.map_join(msgs, "\n", & &1.content)

  defp put_system(body, nil), do: body
  defp put_system(body, prompt), do: Map.put(body, :system, prompt)

  defp format_message(%Message.Human{content: c}), do: %{role: "user", content: c}
  defp format_message(%Message.AI{content: c}), do: %{role: "assistant", content: c}
  defp format_message(%{role: _, content: _} = raw), do: raw

  defp parse_response(%{"content" => [%{"text" => text} | _]}) do
    {:ok, Message.ai(text)}
  end

  defp parse_response(body), do: {:error, {:unexpected_response, body}}
end
