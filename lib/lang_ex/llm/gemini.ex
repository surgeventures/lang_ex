defmodule LangEx.LLM.Gemini do
  @moduledoc """
  Google Gemini chat adapter.

  Supports Gemini models via the `/v1beta/models/{model}:generateContent` endpoint.
  """

  @behaviour LangEx.LLM

  alias LangEx.Config
  alias LangEx.Message

  @base_url "https://generativelanguage.googleapis.com/v1beta"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Config.api_key!(:gemini, opts)
    model = Config.model(:gemini, opts)

    {system_instruction, contents} = extract_system(messages)

    body =
      %{contents: Enum.map(contents, &format_content/1)}
      |> put_system_instruction(system_instruction)
      |> put_generation_config(opts)

    with {:ok, %{status: 200, body: response}} <- do_request(api_key, model, body) do
      parse_response(response)
    else
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_request(api_key, model, body) do
    Req.post("#{@base_url}/models/#{model}:generateContent",
      json: body,
      headers: [
        {"x-goog-api-key", api_key},
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

  defp put_system_instruction(body, nil), do: body

  defp put_system_instruction(body, text) do
    Map.put(body, :system_instruction, %{parts: [%{text: text}]})
  end

  defp put_generation_config(body, opts) do
    config =
      %{}
      |> maybe_put(:temperature, opts[:temperature])
      |> maybe_put(:maxOutputTokens, opts[:max_tokens])

    case map_size(config) do
      0 -> body
      _ -> Map.put(body, :generationConfig, config)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_content(%Message.Human{content: c}), do: %{role: "user", parts: [%{text: c}]}
  defp format_content(%Message.AI{content: c}), do: %{role: "model", parts: [%{text: c}]}

  defp format_content(%{role: _, content: _} = raw),
    do: %{role: raw.role, parts: [%{text: raw.content}]}

  defp parse_response(%{
         "candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]
       }) do
    {:ok, Message.ai(text)}
  end

  defp parse_response(body), do: {:error, {:unexpected_response, body}}
end
