defmodule LangEx.Tool.AnnotationTest do
  use ExUnit.Case, async: true

  alias LangEx.Message
  alias LangEx.Tool.Annotation, as: ToolAnnotation

  describe "annotate/2" do
    test "returns empty map when no annotations needed" do
      messages = [
        Message.human("query"),
        Message.ai("let me check",
          tool_calls: [%Message.ToolCall{name: "search", id: "1", args: %{}}]
        ),
        Message.tool(String.duplicate("data", 100), "1")
      ]

      assert %{} = ToolAnnotation.annotate(messages)
    end

    test "annotates empty tool results" do
      messages = [
        Message.ai("check",
          tool_calls: [%Message.ToolCall{name: "search", id: "1", args: %{}}]
        ),
        Message.tool("", "1")
      ]

      assert %{messages: annotated} = ToolAnnotation.annotate(messages)
      last = List.last(annotated)
      assert %Message.Human{} = last
      assert String.contains?(last.content, "little or no data")
    end

    test "annotates error tool results" do
      messages = [
        Message.ai("check",
          tool_calls: [%Message.ToolCall{name: "query", id: "1", args: %{}}]
        ),
        Message.tool(~s({"error": "connection timed out"}), "1")
      ]

      assert %{messages: annotated} = ToolAnnotation.annotate(messages)
      last = List.last(annotated)
      assert String.contains?(last.content, "Tool error")
      assert String.contains?(last.content, "timed out")
    end

    test "annotates large tool results" do
      large = String.duplicate("x", 60_000)

      messages = [
        Message.ai("check",
          tool_calls: [%Message.ToolCall{name: "query", id: "1", args: %{}}]
        ),
        Message.tool(large, "1")
      ]

      assert %{messages: annotated} = ToolAnnotation.annotate(messages)
      last = List.last(annotated)
      assert String.contains?(last.content, "Large result set")
    end

    test "uses custom error_detector" do
      custom_detector = fn content -> String.contains?(content, "CUSTOM_ERROR") end

      messages = [
        Message.ai("check",
          tool_calls: [%Message.ToolCall{name: "query", id: "1", args: %{}}]
        ),
        Message.tool("CUSTOM_ERROR: something broke", "1")
      ]

      assert %{messages: _} =
               ToolAnnotation.annotate(messages, error_detector: custom_detector)
    end
  end

  describe "tool_results_substantive?/2" do
    test "returns true for substantive results" do
      messages = [
        Message.ai("check",
          tool_calls: [%Message.ToolCall{name: "q", id: "1", args: %{}}]
        ),
        Message.tool(String.duplicate("data", 100), "1")
      ]

      assert ToolAnnotation.tool_results_substantive?(messages)
    end

    test "returns false for empty results" do
      messages = [
        Message.ai("check",
          tool_calls: [%Message.ToolCall{name: "q", id: "1", args: %{}}]
        ),
        Message.tool("", "1")
      ]

      refute ToolAnnotation.tool_results_substantive?(messages)
    end

    test "returns false for error results" do
      messages = [
        Message.ai("check",
          tool_calls: [%Message.ToolCall{name: "q", id: "1", args: %{}}]
        ),
        Message.tool(~s({"error": "not found"}), "1")
      ]

      refute ToolAnnotation.tool_results_substantive?(messages)
    end
  end

  describe "latest_tool_results/1" do
    test "extracts trailing tool messages" do
      messages = [
        Message.human("hi"),
        Message.ai("check",
          tool_calls: [
            %Message.ToolCall{name: "a", id: "1", args: %{}},
            %Message.ToolCall{name: "b", id: "2", args: %{}}
          ]
        ),
        Message.tool("result a", "1"),
        Message.tool("result b", "2")
      ]

      results = ToolAnnotation.latest_tool_results(messages)
      assert length(results) == 2
      assert [%Message.Tool{content: "result a"}, %Message.Tool{content: "result b"}] = results
    end

    test "returns empty list when no trailing tool messages" do
      messages = [Message.human("hi"), Message.ai("hello")]
      assert [] = ToolAnnotation.latest_tool_results(messages)
    end
  end

  describe "default_error_detector/1" do
    test "detects error key" do
      assert ToolAnnotation.default_error_detector(~s({"error": "bad"}))
    end

    test "detects errors key" do
      assert ToolAnnotation.default_error_detector(~s({"errors": ["one"]}))
    end

    test "returns false for normal JSON" do
      refute ToolAnnotation.default_error_detector(~s({"data": [1,2,3]}))
    end

    test "returns false for empty" do
      refute ToolAnnotation.default_error_detector("")
    end

    test "returns false for non-JSON" do
      refute ToolAnnotation.default_error_detector("plain text result")
    end
  end

  describe "default_guidance/1" do
    test "timeout guidance" do
      result = ToolAnnotation.default_guidance(~s({"error": "connection timed out"}))
      assert String.contains?(result, "too broad")
    end

    test "not found guidance" do
      result = ToolAnnotation.default_guidance(~s({"error": "resource not found"}))
      assert String.contains?(result, "not found")
    end

    test "rate limit guidance" do
      result = ToolAnnotation.default_guidance(~s({"error": "429 rate limit exceeded"}))
      assert String.contains?(result, "Rate limited")
    end

    test "server error guidance" do
      result = ToolAnnotation.default_guidance(~s({"error": "500 internal server error"}))
      assert String.contains?(result, "transient")
    end

    test "generic error guidance" do
      result = ToolAnnotation.default_guidance(~s({"error": "something weird happened"}))
      assert String.contains?(result, "different tool")
    end
  end
end
