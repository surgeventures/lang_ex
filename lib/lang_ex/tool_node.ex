defmodule LangEx.ToolNode do
  @moduledoc """
  Graph node for executing tool calls from AI messages.

  Extracts `tool_calls` from the last `%Message.AI{}`, dispatches each
  call to its matching `%LangEx.Tool{}` in parallel, and returns
  `%Message.Tool{}` results.

  ## Usage in a graph

      tools = [
        %LangEx.Tool{
          name: "get_weather",
          description: "Get weather for a city",
          parameters: %{...},
          function: fn %{"city" => city} -> %{temp: 22, city: city} end
        }
      ]

      graph =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:agent, ChatModel.node(model: "gpt-4o", tools: tools))
        |> Graph.add_node(:tools, LangEx.ToolNode.node(tools))
        |> Graph.add_conditional_edges(:agent, &LangEx.ToolNode.tools_condition/1, %{
          tools: :tools,
          __end__: :__end__
        })
        |> Graph.add_edge(:__start__, :agent)
        |> Graph.add_edge(:tools, :agent)
        |> Graph.compile()

  ## Options

    * `:messages_key` — state key holding the message list (default `:messages`)
    * `:handle_tool_errors` — error handling strategy (default `true`):
      - `true`  — catch all errors, return error `%Message.Tool{}`
      - `false` — let exceptions propagate
      - `String.t()` — catch all, return this string as error content
      - `(Exception.t() -> String.t())` — custom handler
    * `:wrap_tool_call` — interceptor `fn(request, execute) -> result`
  """

  alias LangEx.Message
  alias LangEx.Tool

  @invalid_tool_template "Error: ~s is not a valid tool, try one of [~s]."
  @tool_error_template "Error: ~s\n Please fix your mistakes."

  defmodule ToolCallRequest do
    @moduledoc """
    Tool execution request passed to `wrap_tool_call` interceptors.

    Fields:

      * `:tool_call` — `%Message.ToolCall{}` from the AI message
      * `:tool` — `%LangEx.Tool{}` or `nil` when unregistered
      * `:state` — current graph state
      * `:store` — persistent store (or `nil`)
    """
    defstruct [:tool_call, :tool, :state, :store]

    @type t :: %__MODULE__{
            tool_call: LangEx.Message.ToolCall.t(),
            tool: LangEx.Tool.t() | nil,
            state: map(),
            store: term()
          }
  end

  @type error_handler ::
          boolean()
          | String.t()
          | (Exception.t() -> String.t())

  @doc """
  Returns a graph node function that executes tool calls.

  The returned function reads the last `%Message.AI{}` from state,
  executes each `tool_call` in parallel, and returns the results
  as `%Message.Tool{}` messages under the configured messages key.
  """
  @spec node([Tool.t()], keyword()) :: (map() -> map())
  def node(tools, opts \\ []) do
    messages_key = Keyword.get(opts, :messages_key, :messages)
    handle_errors = Keyword.get(opts, :handle_tool_errors, true)
    wrapper = Keyword.get(opts, :wrap_tool_call)

    tools_by_name = Map.new(tools, fn %Tool{name: name} = tool -> {name, tool} end)

    fn state ->
      messages = Map.fetch!(state, messages_key)
      tool_calls = extract_tool_calls(messages)

      results =
        execute_all(tool_calls, tools_by_name, state, handle_errors, wrapper)

      %{messages_key => results}
    end
  end

  @doc """
  Routing condition for tool-calling workflows.

  Returns `:tools` when the last message has pending tool calls,
  `:__end__` otherwise. Use with `Graph.add_conditional_edges/4`.

  ## Options

    * `:messages_key` — state key (default `:messages`)
  """
  @spec tools_condition(map(), keyword()) :: :tools | :__end__
  def tools_condition(state, opts \\ []) do
    messages_key = Keyword.get(opts, :messages_key, :messages)

    state
    |> Map.get(messages_key, [])
    |> List.last()
    |> has_tool_calls?()
  end

  defp has_tool_calls?(%Message.AI{tool_calls: [_ | _]}), do: :tools
  defp has_tool_calls?(_), do: :__end__

  # --- Execution pipeline ---

  defp extract_tool_calls(messages) do
    case List.last(messages) do
      %Message.AI{tool_calls: calls} when calls != [] -> calls
      _ -> []
    end
  end

  defp execute_all(tool_calls, tools_by_name, state, handle_errors, wrapper) do
    old_trap = Process.flag(:trap_exit, true)

    try do
      tasks =
        Enum.map(tool_calls, fn call ->
          Task.async(fn -> run_one(call, tools_by_name, state, handle_errors, wrapper) end)
        end)

      Enum.map(tasks, fn task ->
        case Task.yield(task, 30_000) || Task.shutdown(task) do
          {:ok, result} ->
            result

          {:exit, {exception, stacktrace}} when is_exception(exception) ->
            reraise exception, stacktrace

          {:exit, reason} ->
            exit(reason)

          nil ->
            raise "Tool execution timed out"
        end
      end)
    after
      Process.flag(:trap_exit, old_trap)
      drain_exits()
    end
  end

  defp drain_exits do
    receive do
      {:EXIT, _, _} -> drain_exits()
    after
      0 -> :ok
    end
  end

  defp run_one(call, tools_by_name, state, handle_errors, wrapper) do
    tool = Map.get(tools_by_name, call.name)

    request = %ToolCallRequest{
      tool_call: call,
      tool: tool,
      state: state,
      store: nil
    }

    execute_fn = fn req ->
      do_execute(req, tools_by_name, handle_errors)
    end

    case wrapper do
      nil ->
        execute_fn.(request)

      wrap when is_function(wrap, 2) ->
        try do
          wrap.(request, execute_fn)
        rescue
          e ->
            if handle_errors == false, do: reraise(e, __STACKTRACE__)
            format_error(e, call, handle_errors)
        end
    end
  end

  defp do_execute(%ToolCallRequest{tool: nil, tool_call: call}, tools_by_name, handle_errors) do
    case handle_errors do
      false ->
        available = tools_by_name |> Map.keys() |> Enum.join(", ")

        raise ArgumentError,
              :io_lib.format(@invalid_tool_template, [call.name, available]) |> to_string()

      _ ->
        invalid_tool_message(call, tools_by_name)
    end
  end

  defp do_execute(
         %ToolCallRequest{tool: tool, tool_call: call, state: state},
         _tools_by_name,
         handle_errors
       ) do
    try do
      result = call_function(tool.function, call.args, state, call.id)
      Message.tool(encode_result(result), call.id)
    rescue
      e ->
        if handle_errors == false, do: reraise(e, __STACKTRACE__)
        format_error(e, call, handle_errors)
    end
  end

  defp call_function(fun, args, state, tool_call_id) do
    case Function.info(fun, :arity) do
      {:arity, 1} -> fun.(args)
      {:arity, 2} -> fun.(args, %{state: state, store: nil, tool_call_id: tool_call_id})
    end
  end

  defp format_error(exception, call, handle_errors) do
    case handle_errors do
      true ->
        error_content =
          :io_lib.format(@tool_error_template, [Exception.message(exception)])
          |> to_string()

        Message.tool(error_content, call.id)

      message when is_binary(message) ->
        Message.tool(message, call.id)

      handler when is_function(handler, 1) ->
        Message.tool(handler.(exception), call.id)
    end
  end

  defp invalid_tool_message(call, tools_by_name) do
    available = tools_by_name |> Map.keys() |> Enum.join(", ")

    content =
      :io_lib.format(@invalid_tool_template, [call.name, available])
      |> to_string()

    Message.tool(content, call.id)
  end

  defp encode_result(result) when is_binary(result), do: result

  defp encode_result(result) do
    case Jason.encode(result) do
      {:ok, json} -> json
      {:error, _} -> inspect(result)
    end
  end
end
