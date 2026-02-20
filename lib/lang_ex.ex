defmodule LangEx do
  @moduledoc """
  LangEx — LangGraph for Elixir.

  A graph-based agent orchestration library inspired by LangGraph.
  Build stateful, multi-step LLM workflows using nodes, edges,
  conditional routing, and composable state reducers.

  ## Quick Start

      alias LangEx.Graph
      alias LangEx.Message

      graph =
        Graph.new(messages: {[], &Message.add_messages/2})
        |> Graph.add_node(:greet, fn state ->
          name = hd(state.messages).content
          %{messages: [Message.ai("Hello, \#{name}!")]}
        end)
        |> Graph.add_edge(:__start__, :greet)
        |> Graph.add_edge(:greet, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("World")]})
  """

  alias LangEx.CompiledGraph

  @doc "Executes a compiled graph with the given input state."
  @spec invoke(CompiledGraph.t(), map() | LangEx.Types.Command.t(), keyword()) ::
          {:ok, map()} | {:interrupt, term(), map()} | {:error, term()}
  defdelegate invoke(graph, input, opts \\ []), to: CompiledGraph

  @doc "Returns a lazy stream of execution events from the compiled graph."
  defdelegate stream(graph, input, opts \\ []), to: LangEx.Stream
end
