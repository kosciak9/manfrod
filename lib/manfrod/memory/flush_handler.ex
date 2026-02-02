defmodule Manfrod.Memory.FlushHandler do
  @moduledoc """
  Handles memory extraction on conversation idle.

  Subscribes to the event bus and triggers extraction
  when the agent broadcasts an :idle event. The Extractor
  fetches pending messages directly from the database.
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
  def handle_info({:activity, %Activity{type: :idle}}, state) do
    Logger.info("FlushHandler: idle detected, triggering extraction")
    Extractor.extract_async()
    {:noreply, state}
  end

  def handle_info({:activity, %Activity{}}, state) do
    # Ignore other event types
    {:noreply, state}
  end
end
