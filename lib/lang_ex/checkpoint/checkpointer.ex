defmodule LangEx.Checkpointer do
  @moduledoc """
  Behaviour for checkpoint persistence backends.

  Implement this behaviour to add custom storage (e.g., S3, DynamoDB).
  Built-in implementations: `LangEx.Checkpointer.Redis`, `LangEx.Checkpointer.Postgres`.
  """

  alias LangEx.Checkpoint

  @type config :: keyword()

  @doc "Persists a checkpoint."
  @callback save(config(), Checkpoint.t()) :: :ok | {:error, term()}

  @doc "Loads the latest checkpoint for the given thread."
  @callback load(config()) :: {:ok, Checkpoint.t()} | :none

  @doc "Lists checkpoints for a thread, most recent first."
  @callback list(config(), keyword()) :: [Checkpoint.t()]
end
