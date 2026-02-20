defmodule LangEx.State do
  @moduledoc """
  State management with reducer support.

  Each key in the state schema can optionally have a reducer function
  `(current_value, update_value) -> merged_value`. Keys without reducers
  use last-write-wins semantics.
  """

  @type reducers :: %{optional(atom()) => (any(), any() -> any())}

  @doc """
  Parses a schema keyword list into `{initial_state, reducers}`.

  Schema entries are either:
  - `key: default_value` (no reducer, last-write-wins)
  - `key: {default_value, reducer_fn}` (custom reducer)
  """
  @spec parse_schema(keyword()) :: {map(), reducers()}
  def parse_schema(schema) do
    Enum.reduce(schema, {%{}, %{}}, fn
      {key, {default, reducer}}, {initial, reducers} when is_function(reducer, 2) ->
        {Map.put(initial, key, default), Map.put(reducers, key, reducer)}

      {key, default}, {initial, reducers} ->
        {Map.put(initial, key, default), reducers}
    end)
  end

  @doc """
  Applies a partial update to the current state using registered reducers.
  Keys present in `update` but absent from `reducers` use last-write-wins.
  Keys in `update` that don't exist in the current state are added.
  """
  @spec apply_update(map(), map(), reducers()) :: map()
  def apply_update(current, update, reducers) do
    Enum.reduce(update, current, fn {key, value}, acc ->
      case Map.fetch(reducers, key) do
        {:ok, reducer} ->
          current_val = Map.get(acc, key)
          Map.put(acc, key, reducer.(current_val, value))

        :error ->
          Map.put(acc, key, value)
      end
    end)
  end
end
