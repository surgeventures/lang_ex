defmodule LangEx.Checkpoint do
  @moduledoc """
  Data structure representing a saved graph execution snapshot.

  Persisted by checkpointer implementations after each super-step,
  enabling pause/resume, time-travel, and fault recovery.
  """

  defstruct [
    :thread_id,
    :checkpoint_id,
    :parent_id,
    :state,
    :next_nodes,
    :step,
    :metadata,
    :pending_interrupts,
    :created_at
  ]

  @type t :: %__MODULE__{
          thread_id: String.t(),
          checkpoint_id: String.t(),
          parent_id: String.t() | nil,
          state: map(),
          next_nodes: [atom()],
          step: non_neg_integer(),
          metadata: map(),
          pending_interrupts: [map()] | nil,
          created_at: DateTime.t()
        }

  @doc "Builds a new checkpoint with an auto-generated ID and timestamp."
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(
      __MODULE__,
      Keyword.merge(
        [checkpoint_id: generate_id(), created_at: DateTime.utc_now()],
        attrs
      )
    )
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
