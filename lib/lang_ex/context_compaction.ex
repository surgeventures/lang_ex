defmodule LangEx.ContextCompaction do
  @moduledoc """
  Manages context window size by compacting older tool-call rounds.

  When the message history exceeds a byte budget, the oldest rounds
  (AI tool-call + tool results) are dropped and replaced with a brief
  summary of what tools were called and their outcomes. This preserves
  the investigation narrative while staying within the LLM's effective
  context window.

  ## Usage

      messages = LangEx.ContextCompaction.compact_if_needed(messages)

      # With custom budget:
      messages = LangEx.ContextCompaction.compact_if_needed(messages, max_bytes: 100_000)

  ## Options

  - `:max_bytes` — byte budget for the message list (default `200_000`)
  - `:min_rounds_to_keep` — never drop below this many rounds (default `2`)
  - `:error_detector` — `fn(content :: String.t()) -> boolean()` to detect
    error payloads in tool results (default: JSON `"error"`/`"errors"` key detection)
  - `:compaction_notice` — `fn(summary_text, dropped_count) -> Message.t()`
    to customize the compaction notice message
  """

  alias LangEx.Message

  require Logger

  @default_max_bytes 200_000
  @default_min_rounds 2
  @empty_result_threshold 200

  @doc """
  Compact messages if total size exceeds the context budget.

  Returns messages unchanged if under budget, or with oldest rounds
  replaced by a summary notice if over budget.
  """
  @spec compact_if_needed([Message.t()], keyword()) :: [Message.t()]
  def compact_if_needed(messages, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if messages_byte_size(messages) <= max_bytes,
      do: messages,
      else: compact(messages, opts)
  end

  @doc "Calculate total byte size of a message list."
  @spec messages_byte_size([Message.t()]) :: non_neg_integer()
  def messages_byte_size(messages) when is_list(messages) do
    Enum.reduce(messages, 0, &(message_byte_size(&1) + &2))
  end

  defp compact([system | rest], opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    min_rounds = Keyword.get(opts, :min_rounds_to_keep, @default_min_rounds)
    error_detector = Keyword.get(opts, :error_detector, &default_error_detector/1)
    notice_builder = Keyword.get(opts, :compaction_notice, &default_compaction_notice/2)

    {rounds, trailing} = chunk_into_rounds(rest)
    total = messages_byte_size([system | rest])
    dropped_count = count_rounds_to_drop(rounds, total, max_bytes, min_rounds)

    if dropped_count == 0 do
      [system | rest]
    else
      {dropped, kept} = Enum.split(rounds, dropped_count)
      kept_flat = List.flatten(kept) ++ trailing

      Logger.info(
        "ContextCompact: dropped #{dropped_count}/#{length(rounds)} rounds " <>
          "(#{messages_byte_size([system | kept_flat])} bytes after)"
      )

      notice =
        dropped
        |> format_dropped_summaries(error_detector)
        |> then(&notice_builder.(&1, dropped_count))

      [system, notice | kept_flat]
    end
  end

  defp default_compaction_notice(summary_text, count) do
    Message.human(
      "[Context compacted — #{count} earlier round(s) removed.]\n\n" <>
        summary_text <>
        "Do NOT re-query these tools with the same arguments. " <>
        "Rely on your prior findings for context."
    )
  end

  defp chunk_into_rounds(messages) do
    {rounds, current, trailing} =
      Enum.reduce(messages, {[], [], []}, fn
        %Message.AI{tool_calls: calls} = msg, {rounds, current, _trailing}
        when is_list(calls) and calls != [] ->
          new_rounds =
            if current == [],
              do: rounds,
              else: rounds ++ [Enum.reverse(current)]

          {new_rounds, [msg], []}

        %Message.Tool{} = msg, {rounds, [_ | _] = current, _trailing} ->
          {rounds, [msg | current], []}

        msg, {rounds, [], trailing} ->
          {rounds, [], trailing ++ [msg]}

        msg, {rounds, current, _trailing} ->
          new_rounds = rounds ++ [Enum.reverse(current)]
          {new_rounds, [], [msg]}
      end)

    final_rounds =
      if current == [], do: rounds, else: rounds ++ [Enum.reverse(current)]

    {final_rounds, trailing}
  end

  defp count_rounds_to_drop(_rounds, total, max_bytes, _min_rounds)
       when total <= max_bytes,
       do: 0

  defp count_rounds_to_drop(rounds, _, _, min_rounds)
       when length(rounds) <= min_rounds,
       do: 0

  defp count_rounds_to_drop([oldest | rest], total, max_bytes, min_rounds) do
    1 + count_rounds_to_drop(rest, total - messages_byte_size(oldest), max_bytes, min_rounds)
  end

  defp format_dropped_summaries([], _error_detector), do: ""

  defp format_dropped_summaries(rounds, error_detector) do
    summaries =
      rounds
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {round_msgs, idx} ->
        {tool_names, outcome} = summarize_round(round_msgs, error_detector)
        "- Round #{idx}: called #{tool_names} -> #{outcome}"
      end)

    "Summary of dropped rounds:\n#{summaries}\n\n"
  end

  defp summarize_round(round_msgs, error_detector) do
    tool_names =
      round_msgs
      |> Enum.flat_map(fn
        %Message.AI{tool_calls: calls} when is_list(calls) ->
          Enum.map(calls, & &1.name)

        _ ->
          []
      end)
      |> Enum.join(", ")
      |> then(&if(&1 == "", do: "unknown", else: &1))

    tool_results = Enum.filter(round_msgs, &match?(%Message.Tool{}, &1))

    outcome =
      cond do
        tool_results == [] ->
          "no results"

        Enum.any?(tool_results, fn %Message.Tool{content: c} ->
          error_detector.(c || "")
        end) ->
          "error"

        Enum.all?(tool_results, fn %Message.Tool{content: c} ->
          byte_size(c || "") < @empty_result_threshold
        end) ->
          "empty/minimal data"

        true ->
          total =
            Enum.reduce(tool_results, 0, fn %Message.Tool{content: c}, acc ->
              acc + byte_size(c || "")
            end)

          "#{div(total, 1000)}KB of data"
      end

    {tool_names, outcome}
  end

  @doc """
  Default error detector for tool results.

  Returns `true` if the content parses as JSON with an `"error"` or
  `"errors"` top-level key.
  """
  @spec default_error_detector(String.t()) :: boolean()
  def default_error_detector(content) when byte_size(content) == 0, do: false

  def default_error_detector(content) do
    case Jason.decode(content) do
      {:ok, %{"error" => _}} -> true
      {:ok, %{"errors" => _}} -> true
      _ -> false
    end
  end

  defp message_byte_size(%Message.Tool{content: c}) when is_binary(c), do: byte_size(c)
  defp message_byte_size(%Message.AI{content: c}) when is_binary(c), do: byte_size(c)
  defp message_byte_size(%Message.Human{content: c}) when is_binary(c), do: byte_size(c)
  defp message_byte_size(%Message.System{content: c}) when is_binary(c), do: byte_size(c)
  defp message_byte_size(_), do: 0
end
