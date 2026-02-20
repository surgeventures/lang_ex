defmodule LangEx.Types.Send do
  @moduledoc """
  Directs execution to a node with a custom state payload.
  Used for map-reduce patterns where the number of edges is dynamic.
  """
  @enforce_keys [:node, :state]
  defstruct [:node, :state]

  @type t :: %__MODULE__{
          node: atom(),
          state: map()
        }
end
