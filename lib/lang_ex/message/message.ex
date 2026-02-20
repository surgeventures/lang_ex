defmodule LangEx.Message do
  @moduledoc """
  Chat message types for LLM interactions.

  Provides struct-based message types and a reducer for accumulating
  messages in graph state.
  """

  defmodule Human do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:content, :id]
    @type t :: %__MODULE__{content: String.t(), id: String.t() | nil}
  end

  defmodule AI do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:content, :id, tool_calls: []]
    @type t :: %__MODULE__{content: String.t(), id: String.t() | nil, tool_calls: list()}
  end

  defmodule System do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:content, :id]
    @type t :: %__MODULE__{content: String.t(), id: String.t() | nil}
  end

  defmodule Tool do
    @moduledoc false
    @derive Jason.Encoder
    defstruct [:content, :tool_call_id, :id]
    @type t :: %__MODULE__{content: String.t(), tool_call_id: String.t(), id: String.t() | nil}
  end

  @type t :: Human.t() | AI.t() | System.t() | Tool.t()

  @doc "Create a human message."
  @spec human(String.t(), keyword()) :: Human.t()
  def human(content, opts \\ []), do: struct!(Human, [{:content, content} | opts])

  @doc "Create an AI message."
  @spec ai(String.t(), keyword()) :: AI.t()
  def ai(content, opts \\ []), do: struct!(AI, [{:content, content} | opts])

  @doc "Create a system message."
  @spec system(String.t(), keyword()) :: System.t()
  def system(content, opts \\ []), do: struct!(__MODULE__.System, [{:content, content} | opts])

  @doc "Create a tool result message."
  @spec tool(String.t(), String.t(), keyword()) :: Tool.t()
  def tool(content, tool_call_id, opts \\ []) do
    struct!(Tool, [{:content, content}, {:tool_call_id, tool_call_id} | opts])
  end

  @doc """
  Reducer that appends new messages to an existing list.
  Messages with matching IDs replace the existing message (for corrections/updates).
  """
  @spec add_messages([t()], [t()] | t()) :: [t()]
  def add_messages(existing, new) when is_list(new) do
    existing_ids = for msg <- existing, id = message_id(msg), id, into: MapSet.new(), do: id

    replacements =
      for msg <- new,
          id = message_id(msg),
          id && MapSet.member?(existing_ids, id),
          into: %{},
          do: {id, msg}

    replaced_ids = MapSet.new(Map.keys(replacements))

    Enum.map(existing, &maybe_replace(&1, replacements)) ++
      Enum.reject(new, &MapSet.member?(replaced_ids, message_id(&1)))
  end

  def add_messages(existing, single), do: add_messages(existing, [single])

  defp maybe_replace(msg, replacements) do
    with id when is_binary(id) <- message_id(msg),
         {:ok, replacement} <- Map.fetch(replacements, id) do
      replacement
    else
      _ -> msg
    end
  end

  defp message_id(%{id: id}) when is_binary(id), do: id
  defp message_id(_), do: nil
end
