defmodule Manfrod.Events do
  @moduledoc """
  Event bus for agent activity.

  Broadcasts Activity events to subscribers via Phoenix.PubSub.
  Enables decoupled handlers for typing indicators, response delivery,
  memory extraction, and audit logging.
  """

  alias Manfrod.Events.Activity

  @pubsub Manfrod.PubSub
  @topic "agent:activity"

  @doc """
  Subscribe to agent activity events.

  Returns :ok. Events are delivered as messages:
  `{:activity, %Activity{}}`
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Broadcast an activity event to all subscribers.
  """
  def broadcast(%Activity{} = activity) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:activity, activity})
  end

  @doc """
  Build and broadcast an activity event.
  """
  def broadcast(type, attrs) when is_atom(type) and is_map(attrs) do
    activity = Activity.new(type, attrs)
    broadcast(activity)
  end
end
