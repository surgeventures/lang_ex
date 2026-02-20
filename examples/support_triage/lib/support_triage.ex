defmodule SupportTriage do
  @moduledoc """
  Support triage + action router example using LangEx.

  Demonstrates branching, conditional routing, shared state,
  multi-LLM-call orchestration, and human-in-the-loop interrupts
  using Gemini via the Google adapter.

  ## Graph

      __start__ -> router -> {qa, rewrite, extract, escalate} -> format -> __end__

  The escalate branch includes a human-approval interrupt: the graph
  pauses after drafting the ticket and waits for approval before
  proceeding to format.

  ## Checkpointing

  Pass a checkpointer to `build_graph/1` to enable interrupts and
  state persistence (e.g., `LangEx.Checkpointer.Postgres`).
  """

  alias LangEx.Graph
  alias LangEx.Message
  alias LangEx.MessagesState

  @model "gemini-2.5-flash"
  @checkpointer LangEx.Checkpointer.Postgres
  @repo SupportTriage.Repo

  @doc """
  Builds and compiles the support triage graph.

  Options:
  - `:checkpointer` - module implementing `LangEx.Checkpointer` (enables interrupts)
  """
  def build_graph(opts \\ []) do
    MessagesState.schema(intent: nil, result: nil, approved: nil)
    |> Graph.new()
    |> Graph.add_node(:router, &route/1)
    |> Graph.add_node(:qa, &handle_qa/1)
    |> Graph.add_node(:rewrite, &handle_rewrite/1)
    |> Graph.add_node(:extract, &handle_extract/1)
    |> Graph.add_node(:escalate, &handle_escalate/1)
    |> Graph.add_node(:approve, &approve/1)
    |> Graph.add_node(:format, &format_output/1)
    |> Graph.add_edge(:__start__, :router)
    |> Graph.add_conditional_edges(:router, &Map.get(&1, :intent), %{
      "qa" => :qa,
      "rewrite" => :rewrite,
      "extract" => :extract,
      "escalate" => :escalate
    })
    |> Graph.add_edge(:qa, :format)
    |> Graph.add_edge(:rewrite, :format)
    |> Graph.add_edge(:extract, :format)
    |> Graph.add_edge(:escalate, :approve)
    |> Graph.add_edge(:approve, :format)
    |> Graph.add_edge(:format, :__end__)
    |> Graph.compile(opts)
  end

  @doc """
  Runs the triage graph with a user message and prints the result.

  Options:
  - `:checkpointer` - checkpointer module for persistence + interrupts
  - `:thread_id` - thread identifier for checkpointing
  """
  def run(user_input, opts \\ []) do
    checkpointer = Keyword.get(opts, :checkpointer, @checkpointer)
    thread_id = Keyword.get(opts, :thread_id, "triage-#{System.unique_integer([:positive])}")
    graph = build_graph(checkpointer: checkpointer)

    IO.puts("\n--- Support Triage Router ---")
    IO.puts("Input: #{user_input}\n")

    config = [thread_id: thread_id, repo: Keyword.get(opts, :repo, @repo)]

    case LangEx.invoke(graph, %{messages: [Message.human(user_input)]}, config: config) do
      {:ok, result} ->
        IO.puts("Intent: #{result.intent}")
        IO.puts("\n--- Result ---")
        IO.puts(result.result)
        IO.puts("")
        result

      {:interrupt, payload, state} ->
        IO.puts("Intent: #{state.intent}")
        IO.puts("\n--- Interrupt: Human Approval Required ---")
        IO.puts("Payload: #{inspect(payload)}")
        IO.puts("Thread ID: #{thread_id}")
        IO.puts("\nResume with:")
        IO.puts(~s|  SupportTriage.resume("#{thread_id}", true)\n|)
        {thread_id, state}
    end
  end

  @doc "Resumes an interrupted graph with an approval decision."
  def resume(thread_id, approved, opts \\ []) do
    checkpointer = Keyword.get(opts, :checkpointer, @checkpointer)
    graph = build_graph(checkpointer: checkpointer)

    config = [thread_id: thread_id, repo: Keyword.get(opts, :repo, @repo)]

    {:ok, result} =
      LangEx.invoke(graph, %LangEx.Types.Command{resume: approved}, config: config)

    IO.puts("\n--- Resumed (approved: #{approved}) ---")
    IO.puts(result.result)
    result
  end

  # --- Node functions ---

  defp route(state) do
    system = Message.system("""
    You are an intent classifier for a support system.
    Classify the user's message into exactly ONE of these categories:
    - qa (factual question or how-to)
    - rewrite (user wants text rewritten or improved)
    - extract (user wants structured data extracted)
    - escalate (urgent issue, complaint, or needs human attention)

    Respond with ONLY the category name, nothing else. One word.
    """)

    {:ok, ai_response} =
      LangEx.LLM.Gemini.chat(
        [system | state.messages],
        model: @model,
        temperature: 0.0,
        max_tokens: 1000
      )

    intent =
      ai_response.content
      |> String.trim()
      |> String.downcase()

    IO.puts("Router classified intent: #{intent}")

    %{intent: intent, messages: [ai_response]}
  end

  defp handle_qa(state), do: call_branch(state, "You are a helpful support agent. Answer concisely.")

  defp handle_rewrite(state) do
    call_branch(state, "Rewrite the user's text in a professional, polished tone. Return only the rewritten text.")
  end

  defp handle_extract(state) do
    call_branch(state, """
    Extract structured information from the user's message.
    Return a JSON object with keys: issue_type, urgency ("low"|"medium"|"high"), product, summary.
    Return ONLY valid JSON, no markdown fences.
    """)
  end

  defp handle_escalate(state) do
    call_branch(state, """
    Draft a formal escalation ticket. Format:
    Subject: [title]
    Priority: [Low/Medium/High/Critical]
    Description: [details]
    Recommended Action: [next steps]
    """)
  end

  defp approve(state) do
    approved = LangEx.Interrupt.interrupt(%{
      type: :escalation_approval,
      ticket_draft: List.last(state.messages).content
    })

    %{approved: approved}
  end

  defp call_branch(state, system_prompt) do
    user_messages = Enum.filter(state.messages, &match?(%Message.Human{}, &1))

    {:ok, ai_response} =
      LangEx.LLM.Gemini.chat(
        [Message.system(system_prompt) | user_messages],
        model: @model,
        temperature: 0.3
      )

    %{messages: [ai_response]}
  end

  defp format_output(state) do
    %{result: List.last(state.messages).content}
  end
end
