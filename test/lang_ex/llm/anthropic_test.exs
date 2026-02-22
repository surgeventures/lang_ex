defmodule LangEx.LLM.AnthropicTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.{Message, Tool}

  @weather_tool %Tool{
    name: "get_weather",
    description: "Get current weather",
    parameters: %{
      type: "object",
      properties: %{
        location: %{type: "string", description: "City name"},
        units: %{type: "string", enum: ["celsius", "fahrenheit"]}
      },
      required: ["location"]
    }
  }

  describe "tool formatting" do
    test "uses input_schema key" do
      expect(Req, :post, fn _url, opts ->
        [tool] = opts[:json].tools

        assert %{
                 name: "get_weather",
                 description: "Get current weather",
                 input_schema: %{type: "object", properties: %{location: _}}
               } = tool

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [%{"type" => "text", "text" => "It's sunny"}]
           }
         }}
      end)

      assert {:ok, %Message.AI{content: "It's sunny"}} =
               LangEx.LLM.Anthropic.chat(
                 [Message.human("Weather?")],
                 tools: [@weather_tool],
                 model: "claude-sonnet-4-20250514",
                 api_key: "test"
               )
    end

    test "preserves parameter types as lowercase" do
      expect(Req, :post, fn _url, opts ->
        [%{input_schema: schema}] = opts[:json].tools

        assert schema.type == "object"

        {:ok,
         %{
           status: 200,
           body: %{"content" => [%{"type" => "text", "text" => "ok"}]}
         }}
      end)

      LangEx.LLM.Anthropic.chat(
        [Message.human("test")],
        tools: [@weather_tool],
        model: "claude-sonnet-4-20250514",
        api_key: "test"
      )
    end
  end
end
