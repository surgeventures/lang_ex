defmodule LangEx.LLM.Registry do
  @moduledoc """
  Provider registry and model resolver for LLM chat models.

  Mirrors LangChain's pattern of separate provider packages with a unified
  `init_chat_model/2` interface. Providers can be registered at compile time
  (built-in) or at runtime via `register_provider/2`.

  ## Usage

      # Resolve by model string (auto-detects provider):
      {LangEx.LLM.OpenAI, opts} = LangEx.LLM.Registry.init_chat_model("gpt-4o")

      # Resolve by provider atom:
      {LangEx.LLM.Anthropic, opts} = LangEx.LLM.Registry.init_chat_model(:anthropic, model: "claude-sonnet-4-20250514")

      # Use in a graph node:
      Graph.add_node(:llm, LangEx.LLM.ChatModel.node(model: "gpt-4o"))
  """

  @registry_key {__MODULE__, :providers}

  @builtin_providers %{
    openai: LangEx.LLM.OpenAI,
    anthropic: LangEx.LLM.Anthropic,
    gemini: LangEx.LLM.Gemini
  }

  @model_prefixes [
    {"gpt-", :openai},
    {"o1", :openai},
    {"o3", :openai},
    {"claude-", :anthropic},
    {"gemini-", :gemini}
  ]

  @doc """
  Resolves a provider module and options from a model string or provider atom.

  Returns `{module, opts}` where `module` implements `LangEx.LLM`.

  ## Examples

      {LangEx.LLM.OpenAI, [model: "gpt-4o"]} = init_chat_model("gpt-4o")
      {LangEx.LLM.Anthropic, []} = init_chat_model(:anthropic)
      {LangEx.LLM.OpenAI, [model: "gpt-4o", temperature: 0.5]} = init_chat_model("gpt-4o", temperature: 0.5)
  """
  @spec init_chat_model(atom() | String.t(), keyword()) :: {module(), keyword()}
  def init_chat_model(model_or_provider, opts \\ [])

  def init_chat_model(provider, opts) when is_atom(provider) do
    {fetch_provider!(provider), opts}
  end

  def init_chat_model(model, opts) when is_binary(model) do
    module = model |> infer_provider!() |> fetch_provider!()
    {module, Keyword.put_new(opts, :model, model)}
  end

  @doc """
  Registers a custom provider at runtime.

  Registered providers are stored in `:persistent_term` and survive
  across function calls but not across node restarts.

  ## Example

      LangEx.LLM.Registry.register_provider(:groq, MyApp.LLM.Groq)
  """
  @spec register_provider(atom(), module()) :: :ok
  def register_provider(name, module) when is_atom(name) and is_atom(module) do
    runtime_providers()
    |> Map.put(name, module)
    |> then(&:persistent_term.put(@registry_key, &1))

    :ok
  end

  @doc "Lists all registered providers (built-in + runtime)."
  @spec list_providers() :: %{atom() => module()}
  def list_providers do
    Map.merge(@builtin_providers, runtime_providers())
  end

  @doc """
  Registers a model prefix pattern for provider inference.

  ## Example

      LangEx.LLM.Registry.register_prefix("llama-", :groq)
  """
  @spec register_prefix(String.t(), atom()) :: :ok
  def register_prefix(prefix, provider) when is_binary(prefix) and is_atom(provider) do
    [{prefix, provider} | runtime_prefixes()]
    |> then(&:persistent_term.put({__MODULE__, :prefixes}, &1))

    :ok
  end

  defp fetch_provider!(provider) do
    list_providers()
    |> Map.fetch(provider)
    |> require_provider!(provider)
  end

  defp require_provider!({:ok, module}, _provider), do: module

  defp require_provider!(:error, provider),
    do:
      raise(
        ArgumentError,
        "unknown provider #{inspect(provider)}, registered: #{inspect(Map.keys(list_providers()))}"
      )

  defp infer_provider!(model) do
    (@model_prefixes ++ runtime_prefixes())
    |> Enum.find(fn {prefix, _} -> String.starts_with?(model, prefix) end)
    |> require_prefix_match!(model)
  end

  defp require_prefix_match!({_, provider}, _model), do: provider

  defp require_prefix_match!(nil, model),
    do:
      raise(
        ArgumentError,
        "cannot infer provider from model #{inspect(model)}, register a prefix with register_prefix/2"
      )

  defp runtime_providers do
    :persistent_term.get(@registry_key, %{})
  end

  defp runtime_prefixes do
    :persistent_term.get({__MODULE__, :prefixes}, [])
  end
end
