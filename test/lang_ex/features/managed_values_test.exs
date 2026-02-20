defmodule LangEx.Features.ManagedValuesTest do
  use ExUnit.Case, async: true

  alias LangEx.Graph

  describe "managed values (remaining_steps)" do
    test "remaining_steps is injected and decrements each step" do
      {:ok, result} =
        Graph.new(counter: {0, fn _old, new -> new end}, seen: {[], &Kernel.++/2})
        |> Graph.add_node(:track, fn state ->
          remaining = state.remaining_steps
          %{counter: state.counter + 1, seen: [remaining]}
        end)
        |> Graph.add_edge(:__start__, :track)
        |> Graph.add_conditional_edges(:track, fn
          %{counter: c} when c >= 3 -> :__end__
          _ -> :track
        end)
        |> Graph.compile()
        |> LangEx.invoke(%{}, recursion_limit: 10)

      assert %{counter: 3, seen: [10, 9, 8]} = result
      refute Map.has_key?(result, :remaining_steps)
    end
  end
end
