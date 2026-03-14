defmodule LangEx.LLM.Resilient do
  @moduledoc """
  Retry-aware LLM wrapper with backoff, telemetry hooks, and fallback.

  Wraps any `LangEx.LLM` provider with automatic retries on transient
  failures (rate limits, transport errors, server errors), linear backoff,
  and configurable callbacks for observability.

  ## Usage

      LangEx.LLM.Resilient.chat(LangEx.LLM.Anthropic, messages,
        model: "claude-opus-4-6",
        tools: tools,
        max_retries: 3,
        retry_base_ms: 3_000
      )

  ## Options

  All options not listed below are forwarded to the underlying provider.

  - `:max_retries` — maximum retry attempts (default `3`)
  - `:retry_base_ms` — base delay between retries in ms (default `3_000`);
    actual delay is `base * (attempt + 1)` (linear backoff)
  - `:retryable?` — `fn(error_reason) -> boolean()` to classify retryable
    errors (default: 429, transport errors, 5xx)
  - `:on_success` — `fn(attempt, duration_ms, ai, usage) -> any()`
  - `:on_retry` — `fn(attempt, duration_ms, wait_ms, reason) -> any()`
  - `:on_error` — `fn(attempt, duration_ms, reason) -> any()`
  - `:fallback` — `fn() -> Message.AI.t()` called on final failure;
    when `nil`, the error propagates as `{:error, reason}`
  """

  alias LangEx.LLM

  require Logger

  @default_max_retries 3
  @default_retry_base_ms 3_000

  @doc """
  Call the provider with automatic retries. Returns `{:ok, %Message.AI{}}`.

  On final failure, returns the fallback message if configured, or
  `{:error, reason}` if no fallback is set.
  """
  @spec chat(module(), [LLM.message()], keyword()) :: LLM.chat_result()
  def chat(provider, messages, opts) do
    case chat_with_usage(provider, messages, opts) do
      {:ok, ai, _usage} -> {:ok, ai}
      {:error, _} = err -> err
    end
  end

  @doc """
  Like `chat/3` but returns `{:ok, %Message.AI{}, usage_map}` with token
  counts and `:duration_ms`.
  """
  @spec chat_with_usage(module(), [LLM.message()], keyword()) ::
          LLM.chat_with_usage_result() | LLM.chat_result()
  def chat_with_usage(provider, messages, opts) do
    do_chat(provider, messages, opts, 0)
  end

  defp do_chat(provider, messages, opts, attempt) do
    {max_retries, opts} = Keyword.pop(opts, :max_retries, @default_max_retries)
    {retry_base_ms, opts} = Keyword.pop(opts, :retry_base_ms, @default_retry_base_ms)
    {retryable_fn, opts} = Keyword.pop(opts, :retryable?, &default_retryable?/1)
    {on_success, opts} = Keyword.pop(opts, :on_success)
    {on_retry, opts} = Keyword.pop(opts, :on_retry)
    {on_error, opts} = Keyword.pop(opts, :on_error)
    {fallback, opts} = Keyword.pop(opts, :fallback)

    start = System.monotonic_time(:millisecond)

    case call_provider(provider, messages, opts) do
      {:ok, ai, usage} ->
        elapsed = System.monotonic_time(:millisecond) - start
        if on_success, do: on_success.(attempt, elapsed, ai, usage)
        {:ok, ai, Map.put(usage, :duration_ms, elapsed)}

      {:error, reason} when attempt < max_retries ->
        elapsed = System.monotonic_time(:millisecond) - start

        if retryable_fn.(reason) do
          wait = retry_base_ms * (attempt + 1)
          if on_retry, do: on_retry.(attempt, elapsed, wait, reason)
          Process.sleep(wait)

          retry_opts =
            opts ++
              [
                max_retries: max_retries,
                retry_base_ms: retry_base_ms,
                retryable?: retryable_fn,
                on_success: on_success,
                on_retry: on_retry,
                on_error: on_error,
                fallback: fallback
              ]

          do_chat(provider, messages, retry_opts, attempt + 1)
        else
          handle_final_error(reason, elapsed, attempt, on_error, fallback)
        end

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start
        handle_final_error(reason, elapsed, attempt, on_error, fallback)
    end
  end

  defp call_provider(provider, messages, opts) do
    if function_exported?(provider, :chat_with_usage, 2) do
      provider.chat_with_usage(messages, opts)
    else
      case provider.chat(messages, opts) do
        {:ok, ai} -> {:ok, ai, %{input_tokens: 0, output_tokens: 0}}
        {:error, _} = err -> err
      end
    end
  end

  defp handle_final_error(reason, elapsed, attempt, on_error, fallback) do
    if on_error, do: on_error.(attempt, elapsed, reason)

    case fallback do
      nil ->
        {:error, reason}

      fun when is_function(fun, 0) ->
        {:ok, fun.(), %{input_tokens: 0, output_tokens: 0, duration_ms: elapsed}}
    end
  end

  @doc """
  Default retryable error classifier.

  Returns `true` for:
  - HTTP 429 (rate limit)
  - `Req.TransportError` (connection issues)
  - HTTP 5xx (server errors)
  """
  @spec default_retryable?(term()) :: boolean()
  def default_retryable?({429, _}), do: true
  def default_retryable?(%{__struct__: Req.TransportError}), do: true
  def default_retryable?({status, _}) when is_integer(status) and status >= 500, do: true
  def default_retryable?(_), do: false

  @doc """
  Format an LLM error reason into a human-readable string.
  """
  @spec format_error(term()) :: String.t()
  def format_error({status, %{"error" => %{"message" => msg}}}) when is_binary(msg) do
    short = msg |> String.split("\n") |> hd() |> String.slice(0, 120)
    "HTTP #{status}: #{short}"
  end

  def format_error({status, body}) when is_integer(status) do
    short = body |> inspect() |> String.slice(0, 200)
    "HTTP #{status}: #{short}"
  end

  def format_error(other), do: inspect(other)
end
