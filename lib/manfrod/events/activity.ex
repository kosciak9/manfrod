defmodule Manfrod.Events.Activity do
  @moduledoc """
  Represents agent activity for event subscribers.

  ## Types

  Agent (conversation):
  - `:thinking` - message received, starting LLM call
  - `:narrating` - agent explaining what it's doing (text between tool calls)
  - `:working` - executing tool
  - `:responding` - final response ready
  - `:idle` - conversation timed out

  Memory:
  - `:memory_searched` - graph search performed
  - `:memory_node_created` - new node created
  - `:memory_link_created` - new link created
  - `:memory_node_processed` - node marked as processed

  Extraction:
  - `:extraction_started` - extraction began
  - `:extraction_completed` - extraction finished successfully
  - `:extraction_failed` - extraction failed

  Retrospection:
  - `:retrospection_started` - retrospection began
  - `:retrospection_completed` - retrospection finished successfully
  - `:retrospection_failed` - retrospection failed

  ## Fields

  - `id` - unique event id (UUID)
  - `source` - origin of the event (:telegram, :memory, :extractor, :retrospector, etc.)
  - `reply_to` - opaque reference for response routing (chat_id, pid, etc.)
  - `type` - activity type atom
  - `meta` - optional map with extra context
  - `timestamp` - when the event occurred
  """

  @type activity_type ::
          :thinking
          | :narrating
          | :working
          | :responding
          | :idle
          | :memory_searched
          | :memory_node_created
          | :memory_link_created
          | :memory_node_processed
          | :extraction_started
          | :extraction_completed
          | :extraction_failed
          | :retrospection_started
          | :retrospection_completed
          | :retrospection_failed

  @type t :: %__MODULE__{
          id: String.t(),
          source: atom(),
          reply_to: term(),
          type: activity_type(),
          meta: map(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:id, :type, :timestamp]
  defstruct [:id, :source, :reply_to, :type, :meta, :timestamp]

  @doc """
  Create a new Activity event.

  ## Examples

      Activity.new(:thinking, %{source: :telegram, reply_to: 456})
      Activity.new(:narrating, %{source: :telegram, reply_to: 456, meta: %{text: "Let me check..."}})
      Activity.new(:working, %{source: :telegram, reply_to: 456, meta: %{tool: "run_shell"}})
      Activity.new(:responding, %{source: :telegram, reply_to: 456, meta: %{content: "Hello!"}})
  """
  def new(type, attrs \\ %{}) when is_atom(type) do
    %__MODULE__{
      id: generate_id(),
      type: type,
      source: Map.get(attrs, :source),
      reply_to: Map.get(attrs, :reply_to),
      meta: Map.get(attrs, :meta, %{}),
      timestamp: DateTime.utc_now()
    }
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
