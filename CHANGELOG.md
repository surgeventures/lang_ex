# Changelog

## v0.1.0 (unreleased)

Initial release.

- StateGraph builder with nodes, edges, conditional routing, and `add_sequence`
- Pregel super-step execution engine with parallel node execution via `Task.Supervisor`
- State reducers (per-key merge functions)
- Command routing (combined state update + control flow)
- Checkpointing (Redis via Redix, PostgreSQL via Ecto)
- Oban-style versioned Postgres migrations (`LangEx.Migration`)
- Interrupts / human-in-the-loop (`LangEx.Interrupt`)
- Streaming (`LangEx.Stream` via `Stream.resource`)
- Runtime context injection (arity-2 node functions)
- Subgraph support (compiled graphs as nodes)
- Send fan-out for dynamic map-reduce patterns
- Managed values (`remaining_steps`)
- ChatModels registry with model-string auto-resolution
- Built-in LLM adapters: OpenAI, Anthropic
- MessagesState convenience schema
- Message types: Human, AI, System, Tool
