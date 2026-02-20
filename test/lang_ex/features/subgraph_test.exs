defmodule LangEx.Features.SubgraphTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph

  describe "subgraphs" do
    test "compiled graph can be used as a node in a parent graph" do
      inner =
        Graph.new(value: 0)
        |> Graph.add_node(:double, fn state -> %{value: state.value * 2} end)
        |> Graph.add_edge(:__start__, :double)
        |> Graph.add_edge(:double, :__end__)
        |> Graph.compile()

      outer =
        Graph.new(value: 0, label: "")
        |> Graph.add_node(:sub, inner)
        |> Graph.add_node(:tag, fn _state -> %{label: "done"} end)
        |> Graph.add_edge(:__start__, :sub)
        |> Graph.add_edge(:sub, :tag)
        |> Graph.add_edge(:tag, :__end__)
        |> Graph.compile()

      {:ok, result} = LangEx.invoke(outer, %{value: 7})

      assert %{value: 14, label: "done"} = result
    end
  end
end
