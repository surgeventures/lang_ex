defmodule LangEx.Features.SendTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph
  alias LangEx.Types.Send

  describe "Send fan-out" do
    test "conditional edge returns Send structs for dynamic dispatch" do
      graph =
        Graph.new(results: {[], &Kernel.++/2})
        |> Graph.add_node(:setup, fn _state -> %{} end)
        |> Graph.add_node(:worker, fn state ->
          %{results: [state[:item] || "default"]}
        end)
        |> Graph.add_edge(:__start__, :setup)
        |> Graph.add_conditional_edges(:setup, fn _state ->
          [
            %Send{node: :worker, state: %{item: "a", results: []}},
            %Send{node: :worker, state: %{item: "b", results: []}}
          ]
        end)
        |> Graph.add_edge(:worker, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(graph, %{})

      assert %{results: []} = result
    end
  end
end
