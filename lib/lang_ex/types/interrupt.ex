defmodule LangEx.Types.Interrupt do
  @moduledoc """
  Represents a pending interrupt returned from graph execution.
  """
  defstruct [:value, :node, :resumable]

  @type t :: %__MODULE__{
          value: term(),
          node: atom(),
          resumable: boolean()
        }
end
