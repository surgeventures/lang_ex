defmodule LangEx.Types.Command do
  @moduledoc """
  Combines a state update with a routing directive.
  Returned from node functions to both update state and control flow.
  The `:resume` field is used to resume interrupted graphs.
  """
  defstruct [:goto, :resume, update: %{}]

  @type t :: %__MODULE__{
          goto: atom() | [atom()] | nil,
          resume: term(),
          update: map()
        }
end
