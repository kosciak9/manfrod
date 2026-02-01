defmodule Manfrod.Memory.FlushHandler do
  @moduledoc """
  Handles memory extraction on conversation idle.

  Subscribes to the event bus and triggers batch extraction
  when the agent broadcasts an :idle event.
  """
  use GenServer

  require Logger

  alias Manfrod.Events
  alias Manfrod.Events.Activity
  alias Manfrod.Memory.Extractor

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Events.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:activity, %Activity{type: :idle} = activity}, state) do
    handle_idle(activity)
    {:noreply, state}
  end

  def handle_info({:activity, %Activity{}}, state) do
    # Ignore other event types
    {:noreply, state}
  end

  defp handle_idle(%Activity{user_id: user_id, meta: %{exchanges: exchanges}})
       when is_list(exchanges) and exchanges != [] do
    Logger.info("FlushHandler: extracting from #{length(exchanges)} exchanges")
    Extractor.extract_batch_async(exchanges, user_id)
  end

  defp handle_idle(_activity) do
    :ok
  end
end
