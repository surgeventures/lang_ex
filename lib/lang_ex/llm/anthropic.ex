defmodule LangEx.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude chat adapter with tool use support.

  Supports Claude Sonnet, Opus, and Haiku models via the `/v1/messages` endpoint.

  ## Tool Calling

  Pass `:tools` (list of `%LangEx.Tool{}`) to enable tool calling.
  The adapter returns `{:ok, %Message.AI{tool_calls: [...]}}` when the
  model requests tool use. Use `LangEx.ToolNode` to execute them.

      LangEx.LLM.Anthropic.chat(messages,
        model: "claude-sonnet-4-20250514",
        tools: [%LangEx.Tool{name: "get_weather", ...}]
      )
  """

  @behaviour LangEx.LLM

  alias LangEx.Config
  alias LangEx.Message
  alias LangEx.Tool

  @base_url "https://api.anthropic.com/v1"
  @api_version "2023-06-01"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Config.api_key!(:anthropic, opts)
    model = Config.model(:anthropic, opts)
    tools = Keyword.get(opts, :tools, [])

    {system_prompt, conversation} = extract_system(messages)

    %{
      model: model,
      messages: Enum.map(conversation, &format_message/1),
      max_tokens: opts[:max_tokens] || 1024
    }
    |> maybe_put(:temperature, opts[:temperature])
    |> put_system(system_prompt)
    |> put_tools(tools)
    |> do_request(api_key)
    |> handle_response()
  end

  defp handle_response({:ok, %{status: 200, body: response}}) do
    response
    |> extract_response()
    |> handle_result(response)
  end

  defp handle_response({:ok, %{status: status, body: resp_body}}),
    do: {:error, {status, resp_body}}

  defp handle_response({:error, reason}),
    do: {:error, reason}

  defp handle_result({:text, content}, _),
    do: {:ok, Message.ai(content)}

  defp handle_result({:tool_use, tool_uses}, response) do
    {:ok,
     Message.ai(extract_text_parts(response), tool_calls: Enum.map(tool_uses, &parse_tool_use/1))}
  end

  defp handle_result(:error, response),
    do: {:error, {:unexpected_response, response}}

  defp parse_tool_use(%{"id" => id, "name" => name, "input" => input}),
    do: %Message.ToolCall{name: name, id: id, args: input}

  defp extract_response(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> classify_content(content)
  end

  defp extract_response(_), do: :error

  defp classify_content([_ | _] = tool_uses, _), do: {:tool_use, tool_uses}

  defp classify_content([], content) do
    content
    |> Enum.find(&(&1["type"] == "text"))
    |> to_text_result()
  end

  defp to_text_result(%{"text" => t}), do: {:text, t}
  defp to_text_result(_), do: :error

  defp extract_text_parts(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp extract_text_parts(_), do: ""

  defp do_request(body, api_key) do
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

  defp put_tools(body, []), do: body

  defp put_tools(body, tools) do
    tools
    |> Enum.map(&format_tool/1)
    |> then(&Map.put(body, :tools, &1))
  end

  defp format_tool(%Tool{name: n, description: d, parameters: p}),
    do: %{name: n, description: d, input_schema: p}

  defp format_tool(raw), do: raw

  defp format_message(%Message.Human{content: c}), do: %{role: "user", content: c}

  defp format_message(%Message.AI{content: c, tool_calls: []}),
    do: %{role: "assistant", content: c}

  defp format_message(%Message.AI{content: c, tool_calls: calls}) when calls != [],
    do: %{role: "assistant", content: text_blocks(c) ++ Enum.map(calls, &format_outgoing_call/1)}

  defp format_message(%Message.Tool{content: c, tool_call_id: id}),
    do: %{
      role: "user",
      content: [%{"type" => "tool_result", "tool_use_id" => id, "content" => c}]
    }

  defp format_message(%{role: _, content: _} = raw), do: raw
  defp format_message(%{role: _} = raw), do: raw

  defp format_message(%{content: c, tool_calls: calls}) when is_list(calls) and calls != [],
    do: %{role: "assistant", content: text_blocks(c) ++ Enum.map(calls, &format_outgoing_call/1)}

  defp format_message(%{content: c, tool_calls: _}),
    do: %{role: "assistant", content: c}

  defp format_message(%{content: c, tool_call_id: id}),
    do: %{
      role: "user",
      content: [%{"type" => "tool_result", "tool_use_id" => id, "content" => c}]
    }

  defp format_message(%{content: c}), do: %{role: "user", content: c}

  defp format_outgoing_call(%Message.ToolCall{name: n, id: id, args: a}),
    do: %{"type" => "tool_use", "id" => id, "name" => n, "input" => a}

  defp format_outgoing_call(%{name: n, id: id, args: a}),
    do: %{"type" => "tool_use", "id" => id, "name" => to_string(n), "input" => a}

  defp format_outgoing_call(raw), do: raw

  defp text_blocks(nil), do: []
  defp text_blocks(""), do: []
  defp text_blocks(text), do: [%{"type" => "text", "text" => text}]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
