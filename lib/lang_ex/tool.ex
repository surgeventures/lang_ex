defmodule LangEx.Tool do
  @moduledoc """
  Provider-agnostic tool/function definition for LLM tool calling.

  Define tools once using JSON Schema parameter format, then pass them
  to any LLM adapter. Each adapter translates to its native wire format.

  The optional `:function` field carries the tool's implementation. When
  present, `LangEx.ToolNode` can execute it automatically.

  - **Arity 1** `fn(args)` — receives only the LLM-provided arguments map.
  - **Arity 2** `fn(args, context)` — receives args plus a context map
    `%{state: state, store: store, tool_call_id: id}` for tools that
    need access to graph state or persistent storage.

  ## Examples

      # Schema-only (no function, for manual execution)
      %LangEx.Tool{
        name: "get_weather",
        description: "Get current weather for a location",
        parameters: %{
          type: "object",
          properties: %{
            location: %{type: "string", description: "City name"},
            unit: %{type: "string", enum: ["celsius", "fahrenheit"]}
          },
          required: ["location"]
        }
      }

      # With function (arity 1)
      %LangEx.Tool{
        name: "get_weather",
        description: "Get current weather for a location",
        parameters: %{...},
        function: fn %{"location" => city} -> %{temp: 22, city: city} end
      }

      # With function that accesses graph state (arity 2)
      %LangEx.Tool{
        name: "search",
        description: "Search with conversation context",
        parameters: %{...},
        function: fn %{"query" => q}, %{state: state} ->
          %{results: ["..."], message_count: length(state.messages)}
        end
      }
  """

  @type tool_fn :: (args :: map() -> term()) | (args :: map(), context :: map() -> term())

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          function: tool_fn() | nil
        }

  @derive {Jason.Encoder, except: [:function]}
  defstruct [:name, :description, :parameters, :function]
end
