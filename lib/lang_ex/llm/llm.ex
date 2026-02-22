defmodule LangEx.LLM do
  @moduledoc """
  Behaviour for LLM provider adapters.

  Implement this behaviour to add support for additional LLM providers.

  ## Creating a Custom Provider

  Any module implementing the `chat/2` callback can be used as a provider.
  Here's a minimal example:

      defmodule MyApp.LLM.Groq do
        @behaviour LangEx.LLM

        @impl true
        def chat(messages, opts \\\\ []) do
          api_key = opts[:api_key] || System.get_env("GROQ_API_KEY")
          model = opts[:model] || "llama-3.3-70b"
          tools = opts[:tools] || []
          # Format tools: access struct fields to build your provider's wire format
          formatted_tools = Enum.map(tools, fn
            %LangEx.Tool{name: name, description: desc, parameters: params} ->
              %{type: "function", function: %{name: name, description: desc, parameters: params}}
            raw -> raw
          end)

          # Make API call, return {:ok, Message.ai(...)} or {:ok, Message.ai(nil, tool_calls: [...])}
          # ...
        end
      end

  Then register it so model-string resolution and `ChatModel.node` work:

      # In your application startup or config:
      LangEx.ChatModels.register_provider(:groq, MyApp.LLM.Groq)
      LangEx.ChatModels.register_prefix("llama-", :groq)

  Or use it directly without registration:

      MyApp.LLM.Groq.chat(messages, model: "llama-3.3-70b", api_key: "...")

      # In a graph node:
      ChatModel.node(provider: MyApp.LLM.Groq, model: "llama-3.3-70b")

  ## Using `LangEx.Config` for Custom Providers

  To use the shared config resolution (env vars, app config, explicit opts):

      # In config/runtime.exs:
      config :lang_ex, :providers,
        groq: %{env_key: "GROQ_API_KEY", default_model: "llama-3.3-70b"}

      # Then in your adapter:
      api_key = LangEx.Config.api_key!(:groq, opts)
      model = LangEx.Config.model(:groq, opts)

  ## Tool Calling

  All built-in adapters support tool calling via the `:tools` option:

  - `:tools` - list of `%LangEx.Tool{}` definitions. Each adapter translates
    to its native format by accessing the struct fields directly.

  When the model requests tool calls the adapter returns
  `{:ok, %Message.AI{tool_calls: [...]}}`. Use `LangEx.ToolNode` in your
  graph to execute tool calls and feed results back to the LLM.
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
  - `:tools` - list of `%LangEx.Tool{}` definitions
  """
  @callback chat([message()], keyword()) :: chat_result()
end
