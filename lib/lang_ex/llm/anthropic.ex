defmodule LangEx.LLM.Anthropic do
  @moduledoc """
  Streaming Anthropic Claude adapter with tool use, thinking, and prompt caching.

  Uses `stream: true` by default so data flows continuously, resetting
  the TCP receive timeout with each SSE chunk and avoiding idle-connection
  timeouts from intermediary infrastructure.

  ## Features

  - **Streaming** — SSE-based streaming avoids TCP idle timeouts on long requests
  - **Adaptive thinking** — pass `thinking: true` to enable Claude's extended thinking;
    stream thinking deltas in real time via the `on_thinking` callback
  - **Prompt caching** — system prompts and the last tool definition are annotated
    with `cache_control` for Anthropic's prompt caching beta
  - **Usage tracking** — `chat_with_usage/2` returns token counts including cache metrics
  - **Model-aware defaults** — `max_tokens` defaults based on model family

  ## Tool Calling

  Pass `:tools` (list of `%LangEx.Tool{}`) to enable tool calling.
  The adapter returns `{:ok, %Message.AI{tool_calls: [...]}}` when the
  model requests tool use. Use `LangEx.ToolNode` to execute them.

      LangEx.LLM.Anthropic.chat(messages,
        model: "claude-sonnet-4-20250514",
        tools: [%LangEx.Tool{name: "get_weather", ...}]
      )

  ## Options

  - `:thinking` — enable adaptive thinking (`true` / `false`, default `false`)
  - `:on_thinking` — `fn(accumulated_thinking_text) -> any()` callback
  - `:prompt_caching` — enable prompt caching headers (default `true`)
  - `:stream` — use SSE streaming (default `true`); set `false` for simple requests
  - `:max_tokens` — override max tokens (defaults: 64K for sonnet, 128K otherwise)
  """

  @behaviour LangEx.LLM

  alias LangEx.Config
  alias LangEx.Message
  alias LangEx.Tool

  require Logger

  @base_url "https://api.anthropic.com/v1"
  @api_version "2023-06-01"
  @prompt_caching_beta "prompt-caching-2024-07-31"

  @impl true
  def chat(messages, opts \\ []) do
    case chat_with_usage(messages, opts) do
      {:ok, ai, _usage} -> {:ok, ai}
      {:error, _} = err -> err
    end
  end

  @impl true
  def chat_with_usage(messages, opts \\ []) do
    api_key = Config.api_key!(:anthropic, opts)
    model = Config.model(:anthropic, opts)
    tools = Keyword.get(opts, :tools, [])
    thinking? = Keyword.get(opts, :thinking, false)
    on_thinking = Keyword.get(opts, :on_thinking)
    caching? = Keyword.get(opts, :prompt_caching, true)
    stream? = Keyword.get(opts, :stream, true)

    {system_prompt, conversation} = extract_system(messages)

    body =
      %{
        model: model,
        messages: Enum.map(conversation, &format_message/1),
        max_tokens: opts[:max_tokens] || default_max_tokens(model)
      }
      |> put_stream(stream?)
      |> put_thinking(thinking?, opts)
      |> put_system(system_prompt, caching?)
      |> put_tools(tools, caching?)

    do_request(body, api_key, on_thinking, caching?)
  end

  defp put_stream(body, true), do: Map.put(body, :stream, true)
  defp put_stream(body, false), do: body

  defp put_thinking(body, true, _opts), do: Map.put(body, :thinking, %{type: "adaptive"})

  defp put_thinking(body, false, opts), do: maybe_put(body, :temperature, opts[:temperature])

  defp do_request(body, api_key, on_thinking, caching?) do
    headers =
      [
        {"x-api-key", api_key},
        {"anthropic-version", @api_version},
        {"content-type", "application/json"}
      ]
      |> maybe_add_caching_header(caching?)

    req_opts = [
      json: body,
      headers: headers,
      receive_timeout: 300_000,
      pool_timeout: 60_000
    ]

    dispatch_request(req_opts, on_thinking, body[:stream])
  end

  defp dispatch_request(req_opts, on_thinking, _stream? = true)
       when is_function(on_thinking, 1),
       do: do_streaming_request(req_opts, on_thinking)

  defp dispatch_request(req_opts, on_thinking, _stream?),
    do: do_batch_request(req_opts, on_thinking)

  defp maybe_add_caching_header(headers, true),
    do: headers ++ [{"anthropic-beta", @prompt_caching_beta}]

  defp maybe_add_caching_header(headers, false), do: headers

  defp do_streaming_request(req_opts, on_thinking) do
    ref = make_ref()
    pkey = {__MODULE__, ref}
    Process.put(pkey, initial_sse_state())

    callback = fn {:data, chunk}, {req, resp} ->
      current = Process.get(pkey)
      updated = process_sse_chunk(chunk, current, on_thinking)
      Process.put(pkey, updated)
      {:cont, {req, resp}}
    end

    req_opts = Keyword.put(req_opts, :into, callback)

    result =
      case Req.post("#{@base_url}/messages", req_opts) do
        {:ok, %{status: 200, body: ""}} ->
          build_message(Process.get(pkey))

        {:ok, %{status: 200, body: %Req.Response.Async{}}} ->
          build_message(Process.get(pkey))

        {:ok, %{status: 200, body: raw}} when is_binary(raw) and byte_size(raw) > 0 ->
          parse_sse_response(raw, on_thinking)

        {:ok, %{status: 200, body: %{"content" => _} = json_resp}} ->
          parse_json_response(json_resp)

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {status, resp_body}}

        {:error, reason} ->
          {:error, reason}
      end

    Process.delete(pkey)
    result
  end

  defp do_batch_request(req_opts, on_thinking) do
    case Req.post("#{@base_url}/messages", req_opts) do
      {:ok, %{status: 200, body: raw}} when is_binary(raw) ->
        parse_sse_response(raw, on_thinking)

      {:ok, %{status: 200, body: %{"content" => _} = json_resp}} ->
        parse_json_response(json_resp)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initial_sse_state do
    %{text: %{}, thinking: %{}, tools: %{}, tool_json: %{}, usage: %{}, line_buffer: ""}
  end

  defp process_sse_chunk(chunk, state, on_thinking) do
    {lines, remainder} =
      (state.line_buffer <> chunk)
      |> split_sse_buffer()

    lines
    |> Enum.reduce(%{state | line_buffer: remainder}, &reduce_sse_line(&1, &2, on_thinking))
  end

  defp split_sse_buffer(buffer) do
    case String.split(buffer, "\n") do
      [single] -> {[], single}
      parts -> {Enum.slice(parts, 0..-2//1), List.last(parts)}
    end
  end

  defp reduce_sse_line("data: " <> json_str, acc, on_thinking) do
    case Jason.decode(json_str) do
      {:ok, event} ->
        updated = handle_sse_event(event, acc)
        maybe_emit_thinking(event, updated, on_thinking)
        updated

      _ ->
        acc
    end
  end

  defp reduce_sse_line(_line, acc, _on_thinking), do: acc

  defp maybe_emit_thinking(
         %{"type" => "content_block_delta", "delta" => %{"type" => "thinking_delta"}},
         state,
         on_thinking
       )
       when is_function(on_thinking, 1) do
    thinking_text =
      state.thinking
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("", &elem(&1, 1))

    on_thinking.(thinking_text)
  end

  defp maybe_emit_thinking(_, _, _), do: :ok

  defp parse_sse_response(raw, on_thinking) do
    raw
    |> String.split("\n")
    |> Enum.reduce(initial_sse_state(), &reduce_sse_line(&1, &2, on_thinking))
    |> build_message()
  end

  defp handle_sse_event(
         %{"type" => "content_block_start", "index" => idx, "content_block" => block},
         state
       ) do
    case block do
      %{"type" => "text"} ->
        put_in(state, [:text, idx], "")

      %{"type" => "thinking"} ->
        put_in(state, [:thinking, idx], "")

      %{"type" => "tool_use", "id" => id, "name" => name} ->
        state
        |> put_in([:tools, idx], %{id: id, name: name})
        |> put_in([:tool_json, idx], "")

      _ ->
        state
    end
  end

  defp handle_sse_event(
         %{"type" => "content_block_delta", "index" => idx, "delta" => delta},
         state
       ) do
    case delta do
      %{"type" => "text_delta", "text" => text} ->
        update_in(state, [:text, idx], &((&1 || "") <> text))

      %{"type" => "thinking_delta", "thinking" => text} ->
        update_in(state, [:thinking, idx], &((&1 || "") <> text))

      %{"type" => "input_json_delta", "partial_json" => json} ->
        update_in(state, [:tool_json, idx], &((&1 || "") <> json))

      _ ->
        state
    end
  end

  defp handle_sse_event(%{"type" => "message_delta", "usage" => usage}, state) do
    Map.update(state, :usage, usage, &Map.merge(&1, usage))
  end

  defp handle_sse_event(%{"type" => "message_start", "message" => %{"usage" => usage}}, state) do
    Map.update(state, :usage, usage, &Map.merge(&1, usage))
  end

  defp handle_sse_event(_event, state), do: state

  defp build_message(state) do
    text =
      state.text
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("", &elem(&1, 1))

    thinking =
      state.thinking
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("", &elem(&1, 1))

    tool_calls =
      state.tools
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {idx, tc} ->
        %Message.ToolCall{name: tc.name, id: tc.id, args: decode_tool_args(state.tool_json[idx])}
      end)

    ai = Message.ai(text, tool_calls: tool_calls)
    usage = state.usage |> extract_usage() |> Map.put(:thinking, thinking)
    {:ok, ai, usage}
  end

  defp decode_tool_args(nil), do: %{}

  defp decode_tool_args(json) do
    case Jason.decode(json) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp extract_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_creation_input_tokens: usage["cache_creation_input_tokens"] || 0,
      cache_read_input_tokens: usage["cache_read_input_tokens"] || 0
    }
  end

  defp extract_usage(_) do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0
    }
  end

  defp parse_json_response(%{"content" => content, "usage" => usage}) when is_list(content) do
    parse_json_content(content, extract_usage(usage))
  end

  defp parse_json_response(%{"content" => content}) when is_list(content) do
    parse_json_content(content, %{input_tokens: 0, output_tokens: 0})
  end

  defp parse_json_response(_), do: {:error, :unexpected_response}

  defp parse_json_content(content, usage) do
    tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))

    case tool_uses do
      [_ | _] ->
        text =
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("\n", & &1["text"])

        calls =
          Enum.map(tool_uses, fn %{"id" => id, "name" => name, "input" => input} ->
            %Message.ToolCall{name: name, id: id, args: input}
          end)

        {:ok, Message.ai(text, tool_calls: calls), usage}

      [] ->
        text =
          case Enum.find(content, &(&1["type"] == "text")) do
            %{"text" => t} -> t
            _ -> ""
          end

        {:ok, Message.ai(text), usage}
    end
  end

  defp extract_system(messages) do
    {system_msgs, rest} = Enum.split_with(messages, &match?(%Message.System{}, &1))

    prompt =
      case system_msgs do
        [] -> nil
        msgs -> Enum.map_join(msgs, "\n", & &1.content)
      end

    {prompt, rest}
  end

  defp format_message(%Message.Human{content: c}), do: %{role: "user", content: c}

  defp format_message(%Message.AI{content: c, tool_calls: []}),
    do: %{role: "assistant", content: c}

  defp format_message(%Message.AI{content: c, tool_calls: calls}) when calls != [],
    do: %{
      role: "assistant",
      content: text_blocks(c) ++ Enum.map(calls, &format_outgoing_call/1)
    }

  defp format_message(%Message.Tool{content: c, tool_call_id: id}),
    do: %{
      role: "user",
      content: [%{"type" => "tool_result", "tool_use_id" => id, "content" => c}]
    }

  defp format_message(%{role: _, content: _} = raw), do: raw
  defp format_message(%{role: _} = raw), do: raw

  defp format_message(%{content: c, tool_calls: calls}) when is_list(calls) and calls != [],
    do: %{
      role: "assistant",
      content: text_blocks(c) ++ Enum.map(calls, &format_outgoing_call/1)
    }

  defp format_message(%{content: c, tool_calls: _}), do: %{role: "assistant", content: c}

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

  defp default_max_tokens(model) when is_binary(model) do
    if String.contains?(model, "sonnet"), do: 64_000, else: 128_000
  end

  defp default_max_tokens(_), do: 128_000

  defp put_system(body, nil, _caching?), do: body

  defp put_system(body, prompt, true) do
    Map.put(body, :system, [
      %{
        "type" => "text",
        "text" => prompt,
        "cache_control" => %{"type" => "ephemeral"}
      }
    ])
  end

  defp put_system(body, prompt, false), do: Map.put(body, :system, prompt)

  defp put_tools(body, [], _caching?), do: body

  defp put_tools(body, tools, _caching? = true) do
    tools
    |> Enum.map(&format_tool/1)
    |> mark_last_cacheable()
    |> then(&Map.put(body, :tools, &1))
  end

  defp put_tools(body, tools, _caching?) do
    Map.put(body, :tools, Enum.map(tools, &format_tool/1))
  end

  defp mark_last_cacheable([]), do: []

  defp mark_last_cacheable(tools) do
    {init, [last]} = Enum.split(tools, length(tools) - 1)
    init ++ [Map.put(last, :cache_control, %{"type" => "ephemeral"})]
  end

  defp format_tool(%Tool{name: n, description: d, parameters: p}),
    do: %{name: n, description: d, input_schema: p}

  defp format_tool(raw), do: raw

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
