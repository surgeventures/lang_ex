if Code.ensure_loaded?(Ecto) do
defmodule LangEx.Migration.V1 do
  @moduledoc false
  use Ecto.Migration

  @table :lang_ex_checkpoints

  def up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    create_if_not_exists table(@table, primary_key: false, prefix: prefix) do
      add(:thread_id, :text, null: false)
      add(:checkpoint_id, :text, null: false)
      add(:parent_id, :text)
      add(:state, :jsonb, null: false)
      add(:next_nodes, :jsonb, null: false, default: "[]")
      add(:step, :integer, null: false, default: 0)
      add(:metadata, :jsonb, null: false, default: "{}")
      add(:pending_interrupts, :jsonb)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create_if_not_exists(unique_index(@table, [:thread_id, :checkpoint_id], prefix: prefix))

    create_if_not_exists(
      index(@table, [:thread_id, :created_at],
        prefix: prefix,
        comment: "Fast latest-checkpoint lookup"
      )
    )
  end

  def down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    drop_if_exists(index(@table, [:thread_id, :created_at], prefix: prefix))
    drop_if_exists(unique_index(@table, [:thread_id, :checkpoint_id], prefix: prefix))
    drop_if_exists(table(@table, prefix: prefix))
  end
end
end
