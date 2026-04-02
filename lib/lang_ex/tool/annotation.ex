defmodule LangEx.Tool.Annotation do
  @moduledoc """
  Annotates tool results with error recovery guidance for the LLM.

  After each tool execution round, inspects the results and appends
  human-readable guidance: what went wrong, how to recover, and what
  to try instead. Uses JSON-aware error detection rather than naive
  string matching.

  ## Usage

      # As a post-tool-execution step in a graph:
      annotations = LangEx.Tool.Annotation.annotate(state.messages)
      # => %{messages: [...updated...]} or %{}

  ## Options

  - `:empty_threshold` — byte size below which a result is considered empty (default `200`)
  - `:large_threshold` — byte size above which a result triggers a "large result" note (default `50_000`)
  - `:error_detector` — `fn(content) -> boolean()` (default: JSON error key detection)
  - `:guidance_builder` — `fn(content) -> String.t() | nil` for custom error guidance
  """

  alias LangEx.Message

  @default_empty_threshold 200
  @default_large_threshold 50_000

  @doc """
  Annotate the latest tool results in the message list.

  Returns `%{messages: updated_messages}` if annotations were added,
  or `%{}` if no annotations are needed.
  """
  @spec annotate([Message.t()], keyword()) :: %{optional(:messages) => [Message.t()]}
  def annotate(messages, opts \\ []) do
    empty_threshold = Keyword.get(opts, :empty_threshold, @default_empty_threshold)
    large_threshold = Keyword.get(opts, :large_threshold, @default_large_threshold)
    error_detector = Keyword.get(opts, :error_detector, &default_error_detector/1)
    guidance_builder = Keyword.get(opts, :guidance_builder, &default_guidance/1)

    config = %{
      empty_threshold: empty_threshold,
      large_threshold: large_threshold,
      error_detector: error_detector,
      guidance_builder: guidance_builder
    }

    messages
    |> latest_tool_results()
    |> Enum.flat_map(&build_annotation(&1, config))
    |> wrap_annotations(messages)
  end

  @doc """
  Check whether the latest tool results contain substantive (non-empty,
  non-error) data.
  """
  @spec tool_results_substantive?([Message.t()], keyword()) :: boolean()
  def tool_results_substantive?(messages, opts \\ []) do
    empty_threshold = Keyword.get(opts, :empty_threshold, @default_empty_threshold)
    error_detector = Keyword.get(opts, :error_detector, &default_error_detector/1)

    messages
    |> latest_tool_results()
    |> Enum.any?(&substantive_result?(&1, empty_threshold, error_detector))
  end

  @doc """
  Detect whether a tool result contains a JSON error payload.

  Returns `true` if the content parses as JSON with an `"error"` or
  `"errors"` top-level key.
  """
  @spec default_error_detector(String.t()) :: boolean()
  def default_error_detector(content) when byte_size(content) == 0, do: false

  def default_error_detector(content) do
    content
    |> Jason.decode()
    |> error_payload?()
  end

  defp error_payload?({:ok, %{"error" => _}}), do: true
  defp error_payload?({:ok, %{"errors" => _}}), do: true
  defp error_payload?(_), do: false

  defp substantive_result?(%Message.Tool{content: c}, empty_threshold, error_detector) do
    content = c || ""
    byte_size(content) > empty_threshold and not error_detector.(content)
  end

  @doc "Extract the latest consecutive tool result messages from a message list."
  @spec latest_tool_results([Message.t()]) :: [Message.Tool.t()]
  def latest_tool_results(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&match?(%Message.Tool{}, &1))
    |> Enum.reverse()
  end

  defp wrap_annotations([], _messages), do: %{}

  defp wrap_annotations(notes, messages) do
    %{messages: messages ++ [Message.human("[Tool result notes]\n#{Enum.join(notes, "\n")}")]}
  end

  defp build_annotation(%Message.Tool{content: c}, config) do
    content = c || ""
    size = byte_size(content)
    is_error = config.error_detector.(content)

    classify_annotation(size, is_error, content, config)
  end

  defp classify_annotation(size, false, _content, %{empty_threshold: empty_t})
       when size < empty_t do
    [
      "- Query returned little or no data. Consider broadening " <>
        "the time range, checking the resource name, " <>
        "or trying a different tool."
    ]
  end

  defp classify_annotation(_size, true, content, %{guidance_builder: builder}),
    do: builder.(content) |> List.wrap()

  defp classify_annotation(size, _is_error, _content, %{large_threshold: large_t})
       when size > large_t do
    [
      "- Large result set (#{div(size, 1000)}KB). " <>
        "Focus on the most relevant entries " <>
        "rather than processing everything."
    ]
  end

  defp classify_annotation(_size, _is_error, _content, _config), do: []

  @doc """
  Default error recovery guidance builder.

  Inspects the error message and returns context-specific recovery advice.
  """
  @spec default_guidance(String.t()) :: String.t()
  def default_guidance(content) do
    error_msg = extract_error_message(content)

    guidance =
      error_msg
      |> String.downcase()
      |> guidance_for_error()

    "- Tool error: #{String.slice(error_msg, 0, 150)}. #{guidance}"
  end

  @error_patterns [
    {~w(timed out timeout),
     "The query was too broad or the time range too large. " <>
       "Narrow your filters or use a different tool."},
    {~w(not found 404),
     "The resource was not found. Double-check the ID, " <>
       "name, or query. Try searching for it first."},
    {["not a valid tool", "unknown command"],
     "You used an invalid tool name. Check the available " <>
       "tools in your tool list and use the exact name."},
    {~w(403 forbidden unauthorized),
     "Permission denied. This data source may not be " <>
       "accessible. Try a different tool or data source."},
    {["429", "rate limit"],
     "Rate limited. Do NOT retry immediately. " <>
       "Use a different tool or combine multiple queries."},
    {~w(500 502 503) ++ ["internal server error"],
     "Server error (likely transient). You may retry this " <>
       "ONCE. If it fails again, move on to a different source."},
    {["execution failed", "command failed"],
     "The command failed. Check your parameters and " <>
       "try simplifying the query."}
  ]

  @default_error_guidance "Try a different query, different parameters, " <>
                            "or a different tool entirely. " <>
                            "Do NOT retry the exact same call."

  defp guidance_for_error(lowered) do
    @error_patterns
    |> Enum.find(fn {patterns, _} -> Enum.any?(patterns, &String.contains?(lowered, &1)) end)
    |> matched_guidance()
  end

  defp matched_guidance({_patterns, guidance}), do: guidance
  defp matched_guidance(nil), do: @default_error_guidance

  defp extract_error_message(content) do
    content
    |> Jason.decode()
    |> decoded_error_text()
  end

  defp decoded_error_text({:ok, %{"error" => msg}}) when is_binary(msg), do: msg
  defp decoded_error_text({:ok, %{"error" => %{"message" => msg}}}) when is_binary(msg), do: msg
  defp decoded_error_text({:ok, %{"errors" => [msg | _]}}) when is_binary(msg), do: msg
  defp decoded_error_text(_), do: "unknown error"
end
