if Code.ensure_loaded?(Redix) do
defmodule LangEx.Checkpointer.Redis do
  @moduledoc """
  Redis-backed checkpointer using Redix.

  Checkpoints are stored as JSON under `lang_ex:cp:{thread_id}:{checkpoint_id}`.
  A sorted set `lang_ex:thread:{thread_id}` indexes checkpoint IDs by timestamp
  for ordered retrieval.
  """

  @behaviour LangEx.Checkpointer

  alias LangEx.Checkpoint

  @prefix "lang_ex"
  @default_conn LangEx.Redix

  @impl true
  def save(config, %Checkpoint{} = cp) do
    conn = config[:conn] || @default_conn
    thread_id = Keyword.fetch!(config, :thread_id)
    key = checkpoint_key(thread_id, cp.checkpoint_id)
    index_key = thread_index_key(thread_id)
    score = DateTime.to_unix(cp.created_at, :microsecond)

    with {:ok, _} <- Redix.command(conn, ["SET", key, serialize(cp)]),
         {:ok, _} <- Redix.command(conn, ["ZADD", index_key, score, cp.checkpoint_id]) do
      maybe_apply_ttl(conn, config, key, index_key)
      :ok
    end
  end

  @impl true
  def load(config) do
    conn = config[:conn] || @default_conn
    thread_id = Keyword.fetch!(config, :thread_id)

    with {:ok, [latest_id]} <-
           Redix.command(conn, ["ZREVRANGE", thread_index_key(thread_id), "0", "0"]),
         {:ok, data} when not is_nil(data) <-
           Redix.command(conn, ["GET", checkpoint_key(thread_id, latest_id)]) do
      {:ok, deserialize(data)}
    else
      {:ok, []} -> :none
      {:ok, nil} -> :none
      {:error, _} = err -> err
    end
  end

  @impl true
  def list(config, opts \\ []) do
    conn = config[:conn] || @default_conn
    thread_id = Keyword.fetch!(config, :thread_id)
    limit = Keyword.get(opts, :limit, 100)

    with {:ok, ids} when ids != [] <-
           Redix.command(conn, ["ZREVRANGE", thread_index_key(thread_id), "0", "#{limit - 1}"]),
         keys = Enum.map(ids, &checkpoint_key(thread_id, &1)),
         {:ok, values} <- Redix.command(conn, ["MGET" | keys]) do
      values
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&deserialize/1)
    else
      _ -> []
    end
  end

  defp checkpoint_key(thread_id, cp_id), do: "#{@prefix}:cp:#{thread_id}:#{cp_id}"
  defp thread_index_key(thread_id), do: "#{@prefix}:thread:#{thread_id}"

  defp maybe_apply_ttl(_conn, config, _key, _index_key) when not is_map_key(config, :ttl), do: :ok

  defp maybe_apply_ttl(conn, config, key, index_key) do
    ttl = Keyword.get(config, :ttl)
    do_apply_ttl(conn, ttl, key, index_key)
  end

  defp do_apply_ttl(_conn, nil, _key, _index_key), do: :ok

  defp do_apply_ttl(conn, ttl, key, index_key) do
    Redix.command(conn, ["EXPIRE", key, "#{ttl}"])
    Redix.command(conn, ["EXPIRE", index_key, "#{ttl}"])
  end

  defp serialize(%Checkpoint{} = cp) do
    cp
    |> Map.from_struct()
    |> Map.update!(:next_nodes, &Enum.map(&1, fn n -> Atom.to_string(n) end))
    |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    |> Map.update(:pending_interrupts, nil, &encode_interrupt_nodes/1)
    |> Jason.encode!()
  end

  defp encode_interrupt_nodes(nil), do: nil

  defp encode_interrupt_nodes(interrupts) do
    Enum.map(interrupts, fn i ->
      Map.update(i, :node, nil, &stringify_atom/1)
    end)
  end

  defp stringify_atom(n) when is_atom(n), do: Atom.to_string(n)
  defp stringify_atom(n), do: n

  defp deserialize(json) do
    data = Jason.decode!(json)

    %Checkpoint{
      thread_id: data["thread_id"],
      checkpoint_id: data["checkpoint_id"],
      parent_id: data["parent_id"],
      state: restore_atom_keys(data["state"]),
      next_nodes: Enum.map(data["next_nodes"] || [], &String.to_existing_atom/1),
      step: data["step"],
      metadata: data["metadata"] || %{},
      pending_interrupts: deserialize_interrupts(data["pending_interrupts"]),
      created_at: parse_datetime(data["created_at"])
    }
  end

  defp restore_atom_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp restore_atom_keys(other), do: other

  defp deserialize_interrupts(nil), do: nil

  defp deserialize_interrupts(list) when is_list(list) do
    Enum.map(list, fn i ->
      %{value: i["value"], node: safe_to_atom(i["node"])}
    end)
  end

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(s) when is_binary(s), do: String.to_existing_atom(s)

  defp parse_datetime(nil), do: nil

  defp parse_datetime(s) do
    {:ok, dt, _} = DateTime.from_iso8601(s)
    dt
  end
end
end
