defmodule Manfrod.Events.Activity do
  @moduledoc """
  Represents agent activity for event subscribers.

  ## Types

  - `:thinking` - message received, starting LLM call
  - `:narrating` - agent explaining what it's doing (text between tool calls)
  - `:working` - executing tool
  - `:responding` - final response ready
  - `:idle` - conversation timed out

  ## Fields

  - `id` - unique event id (UUID)
  - `user_id` - who triggered this
  - `source` - origin of the request (:telegram, :cron, :web, etc.)
  - `reply_to` - opaque reference for response routing (chat_id, pid, etc.)
  - `type` - activity type atom
  - `meta` - optional map with extra context
  - `timestamp` - when the event occurred
  """

  @type activity_type :: :thinking | :narrating | :working | :responding | :idle

  @type t :: %__MODULE__{
          id: String.t(),
          user_id: term(),
          source: atom(),
          reply_to: term(),
          type: activity_type(),
          meta: map(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:id, :type, :timestamp]
  defstruct [:id, :user_id, :source, :reply_to, :type, :meta, :timestamp]

  @doc """
  Create a new Activity event.

  ## Examples

      Activity.new(:thinking, %{user_id: 123, source: :telegram, reply_to: 456})
      Activity.new(:narrating, %{user_id: 123, source: :telegram, reply_to: 456, meta: %{text: "Let me check..."}})
      Activity.new(:working, %{user_id: 123, source: :telegram, reply_to: 456, meta: %{tool: "run_shell"}})
      Activity.new(:responding, %{user_id: 123, source: :telegram, reply_to: 456, meta: %{content: "Hello!"}})
  """
  def new(type, attrs \\ %{}) when is_atom(type) do
    %__MODULE__{
      id: generate_id(),
      type: type,
      user_id: Map.get(attrs, :user_id),
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
