defmodule LangEx.ToolAnnotation do
  @moduledoc """
  Annotates tool results with error recovery guidance for the LLM.

  After each tool execution round, inspects the results and appends
  human-readable guidance: what went wrong, how to recover, and what
  to try instead. Uses JSON-aware error detection rather than naive
  string matching.

  ## Usage

      # As a post-tool-execution step in a graph:
      annotations = LangEx.ToolAnnotation.annotate(state.messages)
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
    |> case do
      [] ->
        %{}

      notes ->
        %{
          messages:
            messages ++
              [Message.human("[Tool result notes]\n#{Enum.join(notes, "\n")}")]
        }
    end
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
    |> Enum.any?(fn %Message.Tool{content: c} ->
      content = c || ""

      byte_size(content) > empty_threshold and
        not error_detector.(content)
    end)
  end

  @doc """
  Detect whether a tool result contains a JSON error payload.

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

  @doc "Extract the latest consecutive tool result messages from a message list."
  @spec latest_tool_results([Message.t()]) :: [Message.Tool.t()]
  def latest_tool_results(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&match?(%Message.Tool{}, &1))
    |> Enum.reverse()
  end

  defp build_annotation(%Message.Tool{content: c}, config) do
    content = c || ""
    size = byte_size(content)

    cond do
      size < config.empty_threshold and not config.error_detector.(content) ->
        [
          "- Query returned little or no data. Consider broadening " <>
            "the time range, checking the resource name, " <>
            "or trying a different tool."
        ]

      config.error_detector.(content) ->
        case config.guidance_builder.(content) do
          nil -> []
          guidance -> [guidance]
        end

      size > config.large_threshold ->
        [
          "- Large result set (#{div(size, 1000)}KB). " <>
            "Focus on the most relevant entries " <>
            "rather than processing everything."
        ]

      true ->
        []
    end
  end

  @doc """
  Default error recovery guidance builder.

  Inspects the error message and returns context-specific recovery advice.
  """
  @spec default_guidance(String.t()) :: String.t()
  def default_guidance(content) do
    error_msg = extract_error_message(content)
    lowered = String.downcase(error_msg)

    guidance =
      cond do
        String.contains?(lowered, "timed out") or
            String.contains?(lowered, "timeout") ->
          "The query was too broad or the time range too large. " <>
            "Narrow your filters or use a different tool."

        String.contains?(lowered, "not found") or
            String.contains?(lowered, "404") ->
          "The resource was not found. Double-check the ID, " <>
            "name, or query. Try searching for it first."

        String.contains?(lowered, "not a valid tool") or
            String.contains?(lowered, "unknown command") ->
          "You used an invalid tool name. Check the available " <>
            "tools in your tool list and use the exact name."

        String.contains?(lowered, "403") or
          String.contains?(lowered, "forbidden") or
            String.contains?(lowered, "unauthorized") ->
          "Permission denied. This data source may not be " <>
            "accessible. Try a different tool or data source."

        String.contains?(lowered, "429") or
            String.contains?(lowered, "rate limit") ->
          "Rate limited. Do NOT retry immediately. " <>
            "Use a different tool or combine multiple queries."

        String.contains?(lowered, "500") or
          String.contains?(lowered, "internal server error") or
          String.contains?(lowered, "502") or
            String.contains?(lowered, "503") ->
          "Server error (likely transient). You may retry this " <>
            "ONCE. If it fails again, move on to a different source."

        String.contains?(lowered, "execution failed") or
            String.contains?(lowered, "command failed") ->
          "The command failed. Check your parameters and " <>
            "try simplifying the query."

        true ->
          "Try a different query, different parameters, " <>
            "or a different tool entirely. " <>
            "Do NOT retry the exact same call."
      end

    "- Tool error: #{String.slice(error_msg, 0, 150)}. #{guidance}"
  end

  defp extract_error_message(content) do
    case Jason.decode(content) do
      {:ok, %{"error" => msg}} when is_binary(msg) -> msg
      {:ok, %{"error" => %{"message" => msg}}} when is_binary(msg) -> msg
      {:ok, %{"errors" => [msg | _]}} when is_binary(msg) -> msg
      _ -> "unknown error"
    end
  end
end
