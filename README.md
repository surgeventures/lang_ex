# LangEx

[![Hex.pm](https://img.shields.io/hexpm/v/lang_ex.svg)](https://hex.pm/packages/lang_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/lang_ex)
[![License](https://img.shields.io/hexpm/l/lang_ex.svg)](https://github.com/surgeventures/lang_ex/blob/main/LICENSE)

**LangGraph for Elixir.** A graph-based agent orchestration library for building stateful, multi-step LLM workflows with nodes, edges, conditional routing, state reducers, human-in-the-loop interrupts, and checkpointing (Redis / Postgres). Inspired by [LangGraph](https://www.langchain.com/langgraph), built on BEAM primitives.

## Features

- **StateGraph builder** - declarative graph construction with `add_node`, `add_edge`, `add_conditional_edges`, `add_sequence`
- **Pregel execution engine** - super-step processing with parallel node execution via `Task.Supervisor`
- **State reducers** - per-key merge functions (append lists, sum values, or custom logic)
- **Command routing** - combine state updates and control flow in a single return value
- **Checkpointing** - persist execution state to Redis (default) or PostgreSQL for pause/resume
- **Interrupts** - human-in-the-loop: pause graph execution, wait for external input, resume
- **Streaming** - lazy `Stream` of execution events (node start/end, step boundaries, done)
- **Runtime context** - inject dependencies into nodes without baking them into closures
- **Subgraphs** - use a compiled graph as a node inside a parent graph
- **Send fan-out** - dynamic map-reduce patterns with `%Send{}` from conditional edges
- **Managed values** - `remaining_steps` automatically injected and tracked per super-step
- **ChatModels registry** - auto-resolve model strings (`"gpt-4o"`, `"claude-sonnet-4-20250514"`) to provider modules
- **LLM adapters** - built-in OpenAI, Anthropic, and Gemini, extensible via `LangEx.LLM` behaviour
- **Tool calling** - provider-agnostic `%Tool{}` definitions with optional embedded functions; `ToolNode` executes calls as a graph node with parallel dispatch and condition routing
- **MessagesState** - pre-built schema with `messages` key and `add_messages` reducer

> **Want to try it hands-on?** The [Incident Responder](https://github.com/surgeventures/lang_ex/tree/main/examples/incident_responder) example builds a DevOps agent with the `ToolNode` pattern - multi-step tool chains, conditional routing, human-in-the-loop interrupts, and Postgres checkpointing.

## Installation

Add `lang_ex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:lang_ex, "~> 0.3.0"},

    # Optional: for Redis checkpointer (connection starts automatically when present)
    {:redix, "~> 1.5"},

    # Optional: for PostgreSQL checkpointer (requires Ecto migration, see below)
    {:postgrex, "~> 0.19"},
    {:ecto_sql, "~> 3.12"}
  ]
end
```

The core library (`req`, `jason`) has no checkpointer dependencies. Add only
the ones you need:

| Checkpointer | Required deps |
|---|---|
| `LangEx.Checkpointer.Redis` | `redix` |
| `LangEx.Checkpointer.Postgres` | `postgrex` + `ecto_sql` |
| None (in-memory only) | — |

When `redix` is present, a named Redix connection (`LangEx.Redix`) starts
automatically under `LangEx.Supervisor`. Without it, the connection is simply
skipped.

## Quick Start

```elixir
alias LangEx.Graph
alias LangEx.Message

graph =
  Graph.new(messages: {[], &Message.add_messages/2}, intent: nil)
  |> Graph.add_node(:classify, fn state ->
    content = List.last(state.messages).content
    intent = if String.contains?(content, "weather"), do: "weather", else: "greeting"
    %{intent: intent}
  end)
  |> Graph.add_node(:weather, fn _state -> %{messages: [Message.ai("It's sunny today!")]} end)
  |> Graph.add_node(:greet, fn _state -> %{messages: [Message.ai("Hello there!")]} end)
  |> Graph.add_edge(:__start__, :classify)
  |> Graph.add_conditional_edges(:classify, &Map.get(&1, :intent), %{
    "weather" => :weather,
    "greeting" => :greet
  })
  |> Graph.add_edge(:weather, :__end__)
  |> Graph.add_edge(:greet, :__end__)
  |> Graph.compile()

{:ok, result} = LangEx.invoke(graph, %{messages: [Message.human("What's the weather?")]})
# => %{intent: "weather", messages: [%Message.Human{...}, %Message.AI{content: "It's sunny today!"}]}
```

## Configuration

API keys are resolved in order: explicit opts > Application config > environment variables.

```elixir
# Option 1: Environment variables (recommended for production)
# OPENAI_API_KEY=sk-...
# ANTHROPIC_API_KEY=sk-ant-...

# Option 2: Application config
config :lang_ex, :openai, api_key: "sk-..."
config :lang_ex, :anthropic, api_key: "sk-ant-..."

# Option 3: Explicit opts per call
ChatModel.node(model: "gpt-4o", api_key: "sk-...")
```

### Custom Providers

Register custom providers via application config and runtime registration:

```elixir
# config/config.exs
config :lang_ex, :providers,
  groq: %{env_key: "GROQ_API_KEY", default_model: "llama-3.3-70b"}

# At runtime
LangEx.ChatModels.register_provider(:groq, MyApp.LLM.Groq)
LangEx.ChatModels.register_prefix("llama-", :groq)
```

## ChatModels Registry

Model strings are auto-resolved to provider modules:

```elixir
# Auto-resolved from model string prefix
Graph.add_node(:llm, LangEx.ChatModel.node(model: "gpt-4o"))
Graph.add_node(:llm, LangEx.ChatModel.node(model: "claude-sonnet-4-20250514"))

# Explicit provider
Graph.add_node(:llm, LangEx.ChatModel.node(provider: LangEx.LLM.OpenAI, model: "gpt-4o"))

# Programmatic resolution
{LangEx.LLM.OpenAI, opts} = LangEx.ChatModels.init_chat_model("gpt-4o", temperature: 0.3)
```

## Checkpointing

Checkpointing persists graph execution state after each super-step, enabling pause/resume, fault recovery, and time-travel debugging. Each checkpoint captures the full state, pending next nodes, step counter, and any pending interrupts.

A checkpointer is **required** for interrupts (human-in-the-loop) since state must survive the pause between invocations.

Pass a checkpointer module when compiling a graph and a `thread_id` at invocation time:

```elixir
graph = Graph.new(...) |> ... |> Graph.compile(checkpointer: LangEx.Checkpointer.Redis)

{:ok, result} = LangEx.invoke(graph, input, config: [thread_id: "my-thread"])
```

Both built-in adapters implement the `LangEx.Checkpointer` behaviour:

```elixir
@callback save(config(), Checkpoint.t()) :: :ok | {:error, term()}
@callback load(config()) :: {:ok, Checkpoint.t()} | :none
@callback list(config(), keyword()) :: [Checkpoint.t()]
```

### Redis

Requires the optional `redix` dependency. When `redix` is included, a named
Redix connection starts automatically under `LangEx.Supervisor`.

```elixir
graph =
  Graph.new(value: 0)
  |> Graph.add_node(:inc, fn state -> %{value: state.value + 1} end)
  |> Graph.add_edge(:__start__, :inc)
  |> Graph.add_edge(:inc, :__end__)
  |> Graph.compile(checkpointer: LangEx.Checkpointer.Redis)

{:ok, result} = LangEx.invoke(graph, %{value: 0}, config: [thread_id: "my-thread"])
```

**Key layout:** Checkpoints are stored as JSON under `lang_ex:cp:{thread_id}:{checkpoint_id}`. A sorted set `lang_ex:thread:{thread_id}` indexes checkpoint IDs by timestamp for ordered retrieval.

**TTL support:** Expire old checkpoints automatically by passing a TTL (in seconds) in the config:

```elixir
config = [thread_id: "t1", ttl: 3600]
```

**Custom Redix connection:** Override the default connection name with the `:conn` config key:

```elixir
config = [thread_id: "t1", conn: MyApp.Redix]
```

**Redis URL configuration:**

```elixir
# config/config.exs
config :lang_ex, redis_url: "redis://localhost:6379"
```

### PostgreSQL

Requires the optional `postgrex` and `ecto_sql` dependencies. The adapter
stores checkpoints in a `lang_ex_checkpoints` table with JSONB columns for
state and metadata.

**1. Generate and run the migration** (Oban-style versioned migrations):

```bash
mix ecto.gen.migration add_lang_ex
```

```elixir
defmodule MyApp.Repo.Migrations.AddLangEx do
  use Ecto.Migration

  def up, do: LangEx.Migration.up()
  def down, do: LangEx.Migration.down()
end
```

```bash
mix ecto.migrate
```

**2. Use the Postgres checkpointer:**

```elixir
graph = Graph.new(...) |> ... |> Graph.compile(checkpointer: LangEx.Checkpointer.Postgres)

{:ok, result} = LangEx.invoke(graph, input, config: [repo: MyApp.Repo, thread_id: "t1"])
```

**Schema prefix support:** Isolate LangEx tables in a separate PostgreSQL schema:

```elixir
# In migration
def up, do: LangEx.Migration.up(prefix: "private")
def down, do: LangEx.Migration.down(prefix: "private")
```

**Versioned upgrades:** When upgrading LangEx, generate a new migration targeting the next version:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeLangExToV2 do
  use Ecto.Migration

  def up, do: LangEx.Migration.up(version: 2)
  def down, do: LangEx.Migration.down(version: 2)
end
```

### Choosing an Adapter

| | Redis | PostgreSQL |
|---|---|---|
| **Setup** | Add `redix` dep (auto-starts) | Add `ecto_sql` dep + migration |
| **Best for** | Fast iteration, ephemeral workflows | Durable state, transactional guarantees |
| **Dependencies** | `redix` (optional) | `postgrex` + `ecto_sql` (optional) |
| **TTL / expiry** | Built-in via config | Manage manually or with DB policies |
| **Schema isolation** | Key prefix (`lang_ex:`) | PostgreSQL schema prefix |

## Interrupts (Human-in-the-Loop)

Interrupts let you pause graph execution at any node, surface a payload to the caller, and resume later with a human-provided value. This is the core mechanism for human-in-the-loop workflows like approvals, reviews, and manual overrides.

### How It Works

1. A node calls `LangEx.Interrupt.interrupt(payload)` during execution.
2. The Pregel engine catches the interrupt, saves a checkpoint with `pending_interrupts`, and returns `{:interrupt, payload, state}` to the caller.
3. The caller presents the payload to a human (UI, Slack, email, etc.).
4. When the human responds, the caller resumes the graph by invoking it with `%LangEx.Types.Command{resume: value}` and the same `thread_id`.
5. On resume, the checkpointer loads the saved state, `interrupt/1` returns the resume value instead of throwing, and execution continues from where it left off.

> **Checkpointer required.** Interrupts depend on checkpointing to persist state across the pause. Always compile with a checkpointer when using interrupts.

### Basic Example

```elixir
graph =
  Graph.new(value: 0, approved: false)
  |> Graph.add_node(:check, fn state ->
    approval = LangEx.Interrupt.interrupt("Approve value #{state.value}?")
    %{approved: approval}
  end)
  |> Graph.add_node(:finalize, fn state -> %{value: state.value * 10} end)
  |> Graph.add_edge(:__start__, :check)
  |> Graph.add_edge(:check, :finalize)
  |> Graph.add_edge(:finalize, :__end__)
  |> Graph.compile(checkpointer: LangEx.Checkpointer.Redis)

# First invocation pauses at the interrupt
{:interrupt, "Approve value 42?", _state} =
  LangEx.invoke(graph, %{value: 42}, config: [thread_id: "approval-1"])

# Resume with the human's decision
{:ok, result} =
  LangEx.invoke(graph, %LangEx.Types.Command{resume: true}, config: [thread_id: "approval-1"])
# => %{value: 420, approved: true}
```

### Interrupts with Postgres (Durable Pause/Resume)

For workflows where the pause may last hours or days (e.g. manager approval), use the Postgres checkpointer so state survives application restarts:

```elixir
graph =
  Graph.new(ticket: nil, approved: false)
  |> Graph.add_node(:draft, fn state ->
    %{ticket: "Escalation: #{state.ticket}"}
  end)
  |> Graph.add_node(:approve, fn state ->
    decision = LangEx.Interrupt.interrupt(state.ticket)
    %{approved: decision}
  end)
  |> Graph.add_node(:finalize, fn state -> state end)
  |> Graph.add_edge(:__start__, :draft)
  |> Graph.add_edge(:draft, :approve)
  |> Graph.add_edge(:approve, :finalize)
  |> Graph.add_edge(:finalize, :__end__)
  |> Graph.compile(checkpointer: LangEx.Checkpointer.Postgres)

config = [repo: MyApp.Repo, thread_id: "escalation-#{ticket_id}"]

# Pauses at :approve, state is saved to Postgres
{:interrupt, ticket_text, _state} = LangEx.invoke(graph, %{ticket: "Server down"}, config: config)

# Hours later, after human review, state is loaded from Postgres
{:ok, result} = LangEx.invoke(graph, %LangEx.Types.Command{resume: true}, config: config)
```

### Conditional Interrupts

Not every path through the graph needs to interrupt. Use normal control flow to decide whether to pause:

```elixir
Graph.add_node(:maybe_approve, fn state ->
  if state.needs_approval do
    approved = LangEx.Interrupt.interrupt("Please review: #{state.summary}")
    %{approved: approved}
  else
    %{approved: true}
  end
end)
```

Paths that don't hit `interrupt/1` complete in a single invocation as usual.

## Streaming

Get a lazy stream of execution events:

```elixir
graph
|> LangEx.stream(%{value: 0})
|> Enum.each(fn
  {:node_start, name} -> IO.puts("Starting #{name}...")
  {:node_end, name, _update} -> IO.puts("Finished #{name}")
  {:step_end, step, state} -> IO.inspect(state, label: "Step #{step}")
  {:done, {:ok, result}} -> IO.inspect(result, label: "Final")
  _ -> :ok
end)
```

## Runtime Context

Inject dependencies into nodes without closures:

```elixir
graph =
  Graph.new(greeting: "")
  |> Graph.add_node(:greet, fn state, context ->
    %{greeting: "Hello from #{context.provider}!"}
  end)
  |> Graph.add_edge(:__start__, :greet)
  |> Graph.add_edge(:greet, :__end__)
  |> Graph.compile()

{:ok, result} = LangEx.invoke(graph, %{}, context: %{provider: "OpenAI"})
```

## Subgraphs

Use a compiled graph as a node:

```elixir
inner =
  Graph.new(value: 0)
  |> Graph.add_node(:double, fn state -> %{value: state.value * 2} end)
  |> Graph.add_edge(:__start__, :double)
  |> Graph.add_edge(:double, :__end__)
  |> Graph.compile()

outer =
  Graph.new(value: 0, label: "")
  |> Graph.add_node(:sub, inner)
  |> Graph.add_node(:tag, fn _state -> %{label: "done"} end)
  |> Graph.add_edge(:__start__, :sub)
  |> Graph.add_edge(:sub, :tag)
  |> Graph.add_edge(:tag, :__end__)
  |> Graph.compile()

{:ok, %{value: 14, label: "done"}} = LangEx.invoke(outer, %{value: 7})
```

## Docker Compose (Development)

Start Redis and PostgreSQL for local development:

```bash
cd lang_ex
docker-compose up -d
```

```yaml
# docker-compose.yml
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: lang_ex
      POSTGRES_PASSWORD: lang_ex
      POSTGRES_DB: lang_ex_dev
    ports:
      - "5432:5432"
```

## Extending LangEx

### Custom LLM Provider

Implement the `LangEx.LLM` behaviour and register:

```elixir
defmodule MyApp.LLM.Groq do
  @behaviour LangEx.LLM

  @impl true
  def chat(messages, opts) do
    # Your API call here
    {:ok, LangEx.Message.ai("response")}
  end
end

# Register at application startup
LangEx.ChatModels.register_provider(:groq, MyApp.LLM.Groq)
LangEx.ChatModels.register_prefix("llama-", :groq)
```

### Custom Checkpointer

Implement the `LangEx.Checkpointer` behaviour:

```elixir
defmodule MyApp.Checkpointer.S3 do
  @behaviour LangEx.Checkpointer

  @impl true
  def save(config, checkpoint), do: # ...

  @impl true
  def load(config), do: # ...

  @impl true
  def list(config, opts \\ []), do: # ...
end
```

## License

MIT
