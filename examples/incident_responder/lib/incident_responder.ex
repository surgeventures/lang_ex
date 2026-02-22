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
  alias LangEx.Types.Command

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
    case IO.gets("You: ") do
      :eof ->
        IO.puts("\nSession ended.")

      input ->
        message = String.trim(input)

        cond do
          message in ["quit", "exit", "q"] ->
            IO.puts("\nSession ended.")

          message == "" ->
            repl_loop(session_id, opts)

          true ->
            case chat(session_id, message, opts) do
              {:ok, response} ->
                IO.puts("\nOps: #{response}\n")
                repl_loop(session_id, opts)

              {:done, response} ->
                IO.puts("\nOps: #{response}\n")
                IO.puts("[Incident closed]")

              {:error, reason} ->
                IO.puts("\n[Error: #{inspect(reason)}]\n")
                repl_loop(session_id, opts)
            end
        end
    end
  end

  defp build_config(session_id, opts) do
    [thread_id: session_id, repo: Keyword.get(opts, :repo, @repo)]
  end
end
