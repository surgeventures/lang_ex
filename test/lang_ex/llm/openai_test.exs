defmodule LangEx.LLM.OpenAITest do
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
    test "wraps tool in function type envelope" do
      expect(Req, :post, fn _url, opts ->
        [tool] = opts[:json].tools

        assert %{
                 type: "function",
                 function: %{
                   name: "get_weather",
                   description: "Get current weather",
                   parameters: %{type: "object", properties: %{location: _}}
                 }
               } = tool

        {:ok,
         %{
           status: 200,
           body: %{
             "choices" => [%{"message" => %{"content" => "It's sunny"}}]
           }
         }}
      end)

      assert {:ok, %Message.AI{content: "It's sunny"}} =
               LangEx.LLM.OpenAI.chat(
                 [Message.human("Weather?")],
                 tools: [@weather_tool],
                 model: "gpt-4o-mini",
                 api_key: "test"
               )
    end

    test "preserves parameter types as lowercase" do
      expect(Req, :post, fn _url, opts ->
        [%{function: %{parameters: params}}] = opts[:json].tools

        assert params.type == "object"
        assert params.properties.location.type == "string"

        {:ok,
         %{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => "ok"}}]}
         }}
      end)

      LangEx.LLM.OpenAI.chat(
        [Message.human("test")],
        tools: [@weather_tool],
        model: "gpt-4o-mini",
        api_key: "test"
      )
    end
  end
end
