defmodule IncidentResponder do
  @moduledoc """
  DevOps Incident Response Assistant powered by LangEx.

  A conversational agent that triages alerts, runs diagnostics via tools,
  and takes remediation actions (restart, page on-call, update status page).

  ## Usage

      # Start a new session
      {:ok, session_id, greeting} = IncidentResponder.start_session()

      # Send messages
      {:ok, response} = IncidentResponder.chat(session_id, "api-gateway is returning 503s")
      {:ok, response} = IncidentResponder.chat(session_id, "yes, restart it")

      # Interactive REPL
      IncidentResponder.repl()
  """

  alias IncidentResponder.Graph
  alias LangEx.Command

  @checkpointer LangEx.Checkpointer.Postgres
  @repo IncidentResponder.Repo
  @recursion_limit 100

  @doc """
  Starts a new incident response session.
  Returns `{:ok, session_id, greeting}`.
  """
  def start_session(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "inc-#{System.unique_integer([:positive])}")
    checkpointer = Keyword.get(opts, :checkpointer, @checkpointer)
    graph = Graph.build(checkpointer: checkpointer)
    config = build_config(session_id, opts)

    case LangEx.invoke(graph, %{messages: []}, config: config, recursion_limit: @recursion_limit) do
      {:interrupt, %{response: greeting}, _state} ->
        {:ok, session_id, greeting}

      {:ok, result} ->
        {:ok, session_id, result.last_response || "Ops here. What's the situation?"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a message in an existing session.
  Returns `{:ok, response}` or `{:done, response}` when the conversation ends.
  """
  def chat(session_id, message, opts \\ []) do
    checkpointer = Keyword.get(opts, :checkpointer, @checkpointer)
    graph = Graph.build(checkpointer: checkpointer)
    config = build_config(session_id, opts)

    case LangEx.invoke(graph, %Command{resume: message}, config: config, recursion_limit: @recursion_limit) do
      {:interrupt, %{response: response}, _state} ->
        {:ok, response}

      {:ok, result} ->
        {:done, result.last_response || "Incident resolved. Stay safe out there."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts an interactive REPL. Type "quit" or "exit" to stop.
  """
  def repl(opts \\ []) do
    IO.puts("\n=== Acme Platform - Incident Response ===\n")

    case start_session(opts) do
      {:ok, session_id, greeting} ->
        IO.puts("Ops: #{greeting}\n")
        repl_loop(session_id, opts)

      {:error, reason} ->
        IO.puts("Failed to start session: #{inspect(reason)}")
    end
  end

  defp repl_loop(session_id, opts) do
    IO.gets("You: ")
    |> handle_repl_input(session_id, opts)
  end

  defp handle_repl_input(:eof, _session_id, _opts),
    do: IO.puts("\nSession ended.")

  defp handle_repl_input(input, session_id, opts) do
    input
    |> String.trim()
    |> process_repl_message(session_id, opts)
  end

  defp process_repl_message(message, _session_id, _opts)
       when message in ["quit", "exit", "q"],
       do: IO.puts("\nSession ended.")

  defp process_repl_message("", session_id, opts),
    do: repl_loop(session_id, opts)

  defp process_repl_message(message, session_id, opts) do
    message
    |> then(&chat(session_id, &1, opts))
    |> handle_chat_response(session_id, opts)
  end

  defp handle_chat_response({:ok, response}, session_id, opts) do
    IO.puts("\nOps: #{response}\n")
    repl_loop(session_id, opts)
  end

  defp handle_chat_response({:done, response}, _session_id, _opts) do
    IO.puts("\nOps: #{response}\n")
    IO.puts("[Incident closed]")
  end

  defp handle_chat_response({:error, reason}, session_id, opts) do
    IO.puts("\n[Error: #{inspect(reason)}]\n")
    repl_loop(session_id, opts)
  end

  defp build_config(session_id, opts) do
    [thread_id: session_id, repo: Keyword.get(opts, :repo, @repo)]
  end
end
