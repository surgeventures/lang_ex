defmodule SupportTriageTest do
  use ExUnit.Case, async: false
  use Mimic

  alias LangEx.Message
  alias LangEx.Types.Command

  defp stub_router(intent) do
    stub(LangEx.LLM.Gemini, :chat, fn _messages, opts ->
      response =
        case {opts[:temperature] == 0.0, intent} do
          {true, _} -> intent
          {false, "qa"} -> "You can reset your password from Settings > Security."
          {false, "rewrite"} -> "We appreciate your feedback regarding our documentation."
          {false, "extract"} -> ~s({"issue_type":"login_failure","urgency":"high","product":"mobile_app","summary":"Login broken on mobile"})
          {false, "escalate"} -> "Subject: Critical Login Failure\nPriority: High\nDescription: Users unable to log in.\nRecommended Action: Escalate to engineering."
        end

      {:ok, Message.ai(response)}
    end)
  end

  # --- Routing tests ---

  describe "graph routes to correct branch" do
    test "qa intent classifies and answers" do
      stub_router("qa")

      {:ok, result} =
        SupportTriage.build_graph()
        |> LangEx.invoke(%{messages: [Message.human("How do I reset my password?")]})

      assert %{
               intent: "qa",
               result: "You can reset your password from Settings > Security.",
               messages: [%Message.Human{}, %Message.AI{} | _]
             } = result
    end

    test "rewrite intent classifies and rewrites" do
      stub_router("rewrite")

      {:ok, result} =
        SupportTriage.build_graph()
        |> LangEx.invoke(%{messages: [Message.human("ur docs r confusing")]})

      assert %{
               intent: "rewrite",
               result: "We appreciate your feedback regarding our documentation."
             } = result
    end

    test "extract intent classifies and extracts JSON" do
      stub_router("extract")

      {:ok, result} =
        SupportTriage.build_graph()
        |> LangEx.invoke(%{messages: [Message.human("Login broken on mobile app, urgent")]})

      assert %{intent: "extract", result: result_json} = result
      assert {:ok, %{"issue_type" => "login_failure", "urgency" => "high"}} = Jason.decode(result_json)
    end

    test "escalate intent without checkpointer returns interrupt" do
      stub_router("escalate")

      assert {:interrupt, %{type: :escalation_approval}, _state} =
               SupportTriage.build_graph()
               |> LangEx.invoke(%{messages: [Message.human("Everything is broken!")]})
    end
  end

  # --- Interrupt + checkpointer tests (Postgres) ---

  describe "escalation with Postgres checkpointer (human-in-the-loop)" do
    test "escalate pauses at approval interrupt, resume completes the graph" do
      stub_router("escalate")

      graph = SupportTriage.build_graph(checkpointer: LangEx.Checkpointer.Postgres)
      thread_config = [thread_id: "escalate-test-1", repo: SupportTriage.Repo]

      {:interrupt, payload, paused_state} =
        LangEx.invoke(graph, %{messages: [Message.human("Server is on fire!")]}, config: thread_config)

      assert %{type: :escalation_approval, ticket_draft: draft} = payload
      assert draft =~ "Subject:"
      assert %{intent: "escalate"} = paused_state

      {:ok, result} =
        LangEx.invoke(graph, %Command{resume: true}, config: thread_config)

      assert %{
               intent: "escalate",
               approved: true,
               result: result_text
             } = result

      assert is_binary(result_text)
    end

    test "escalate resume with rejection still completes" do
      stub_router("escalate")

      graph = SupportTriage.build_graph(checkpointer: LangEx.Checkpointer.Postgres)
      thread_config = [thread_id: "escalate-reject-1", repo: SupportTriage.Repo]

      {:interrupt, _, _} =
        LangEx.invoke(graph, %{messages: [Message.human("Urgent issue")]}, config: thread_config)

      {:ok, result} =
        LangEx.invoke(graph, %Command{resume: false}, config: thread_config)

      assert %{approved: false, result: _} = result
    end

    test "non-escalate intents complete without interrupt even with checkpointer" do
      stub_router("qa")

      graph = SupportTriage.build_graph(checkpointer: LangEx.Checkpointer.Postgres)

      {:ok, result} =
        LangEx.invoke(graph, %{messages: [Message.human("How to reset password?")]},
          config: [thread_id: "qa-no-interrupt", repo: SupportTriage.Repo]
        )

      assert %{intent: "qa", result: _, approved: nil} = result
    end
  end

  # --- Structure tests ---

  describe "graph structure" do
    test "build_graph returns a compiled graph with all nodes" do
      assert %LangEx.CompiledGraph{nodes: nodes} = SupportTriage.build_graph()

      assert [:approve, :escalate, :extract, :format, :qa, :rewrite, :router] =
               nodes |> Map.keys() |> Enum.sort()
    end

    test "build_graph with checkpointer sets the checkpointer" do
      graph = SupportTriage.build_graph(checkpointer: LangEx.Checkpointer.Postgres)
      assert graph.checkpointer == LangEx.Checkpointer.Postgres
    end
  end
end
