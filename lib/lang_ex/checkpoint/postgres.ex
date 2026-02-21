if Code.ensure_loaded?(Ecto) do
  defmodule LangEx.Checkpointer.Postgres do
    @moduledoc """
    PostgreSQL-backed checkpointer using Ecto.

    Assumes the `lang_ex_checkpoints` table has been created via
    `LangEx.Migration`. See `LangEx.Migration` for setup instructions.

    ## Config

    The `:repo` key must point to an Ecto.Repo module:

        config = [repo: MyApp.Repo, thread_id: "thread-1"]
        LangEx.Checkpointer.Postgres.save(config, checkpoint)
    """

    @behaviour LangEx.Checkpointer

    import Ecto.Query

    alias LangEx.Checkpoint
    alias LangEx.Checkpointer.Postgres.Schema

    @impl true
    def save(config, %Checkpoint{} = cp) do
      repo = Keyword.fetch!(config, :repo)

      attrs = %{
        thread_id: cp.thread_id,
        checkpoint_id: cp.checkpoint_id,
        parent_id: cp.parent_id,
        state: encode_atom_keys(cp.state),
        next_nodes: Enum.map(cp.next_nodes, &Atom.to_string/1),
        step: cp.step,
        metadata: cp.metadata || %{},
        pending_interrupts: encode_interrupts(cp.pending_interrupts),
        created_at: cp.created_at
      }

      %Schema{}
      |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
      |> repo.insert(
        on_conflict: {:replace, [:state, :next_nodes, :step, :metadata, :pending_interrupts]},
        conflict_target: [:thread_id, :checkpoint_id]
      )

      :ok
    end

    @impl true
    def load(config) do
      repo = Keyword.fetch!(config, :repo)
      thread_id = Keyword.fetch!(config, :thread_id)

      Schema
      |> where([c], c.thread_id == ^thread_id)
      |> order_by([c], desc: c.created_at)
      |> limit(1)
      |> repo.one()
      |> to_checkpoint()
    end

    @impl true
    def list(config, opts \\ []) do
      repo = Keyword.fetch!(config, :repo)
      thread_id = Keyword.fetch!(config, :thread_id)
      row_limit = Keyword.get(opts, :limit, 100)

      Schema
      |> where([c], c.thread_id == ^thread_id)
      |> order_by([c], desc: c.created_at)
      |> limit(^row_limit)
      |> repo.all()
      |> Enum.map(&schema_to_checkpoint/1)
    end

    defp to_checkpoint(nil), do: :none
    defp to_checkpoint(%Schema{} = row), do: {:ok, schema_to_checkpoint(row)}

    defp schema_to_checkpoint(%Schema{} = row) do
      %Checkpoint{
        thread_id: row.thread_id,
        checkpoint_id: row.checkpoint_id,
        parent_id: row.parent_id,
        state: restore_atom_keys(row.state),
        next_nodes: Enum.map(row.next_nodes || [], &String.to_existing_atom/1),
        step: row.step,
        metadata: row.metadata || %{},
        pending_interrupts: deserialize_interrupts(row.pending_interrupts),
        created_at: row.created_at
      }
    end

    defp restore_atom_keys(map) when is_map(map) do
      Map.new(map, fn {k, v} -> {String.to_existing_atom(k), restore_atom_keys(v)} end)
    end

    defp restore_atom_keys(list) when is_list(list), do: Enum.map(list, &restore_atom_keys/1)
    defp restore_atom_keys(other), do: other

    defp encode_atom_keys(map) when is_map(map) do
      Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
    end

    defp encode_interrupts(nil), do: nil

    defp encode_interrupts(list) when is_list(list) do
      Enum.map(list, fn i ->
        Map.new(i, fn
          {:node, v} when is_atom(v) -> {"node", Atom.to_string(v)}
          {k, v} when is_atom(k) -> {Atom.to_string(k), v}
          pair -> pair
        end)
      end)
    end

    defp deserialize_interrupts(nil), do: nil

    defp deserialize_interrupts(list) when is_list(list) do
      Enum.map(list, fn i ->
        %{
          value: i["value"],
          node: safe_to_atom(i["node"])
        }
      end)
    end

    defp safe_to_atom(nil), do: nil
    defp safe_to_atom(s) when is_binary(s), do: String.to_existing_atom(s)
  end
end
