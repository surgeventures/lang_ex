defmodule LangEx.ToolTest do
  use ExUnit.Case, async: true

  alias LangEx.Tool

  describe "struct" do
    test "creates a tool with all fields" do
      assert %Tool{
               name: "get_weather",
               description: "Get current weather",
               parameters: %{type: "object"}
             } = %Tool{
               name: "get_weather",
               description: "Get current weather",
               parameters: %{type: "object", properties: %{}, required: []}
             }
    end

    test "defaults to nil fields" do
      assert %Tool{name: nil, description: nil, parameters: nil, function: nil} = %Tool{}
    end

    test "accepts an arity-1 function" do
      tool = %Tool{
        name: "echo",
        description: "Echo args",
        parameters: %{},
        function: fn args -> args end
      }

      assert tool.function.(%{"x" => 1}) == %{"x" => 1}
    end

    test "accepts an arity-2 function for state access" do
      tool = %Tool{
        name: "stateful",
        description: "Uses state",
        parameters: %{},
        function: fn args, %{state: state} ->
          {args, map_size(state)}
        end
      }

      assert tool.function.(%{"q" => "hi"}, %{state: %{a: 1, b: 2}}) == {%{"q" => "hi"}, 2}
    end

    test "JSON encodes without the function field" do
      tool = %Tool{
        name: "t",
        description: "d",
        parameters: %{},
        function: fn _ -> :ok end
      }

      {:ok, json} = Jason.encode(tool)
      decoded = Jason.decode!(json)
      assert decoded["name"] == "t"
      refute Map.has_key?(decoded, "function")
    end
  end
end
