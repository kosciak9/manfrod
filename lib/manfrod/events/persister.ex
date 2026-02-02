defmodule Manfrod.Events.Persister do
  @moduledoc """
  GenServer that subscribes to agent activity and persists events.

  Also handles periodic cleanup of events older than 7 days.
  """
  use GenServer

  require Logger

  alias Manfrod.Events
  alias Manfrod.Events.Activity
  alias Manfrod.Events.Store

  @retention_days 7
  @cleanup_interval :timer.hours(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Events.subscribe()
    schedule_cleanup()
    Logger.info("Events.Persister started, subscribed to activity events")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:activity, %Activity{} = activity}, state) do
    case Store.insert(activity) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist activity: #{inspect(changeset.errors)}")
    end

    {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    {count, _} = Store.delete_older_than(@retention_days)

    if count > 0 do
      Logger.info("Cleaned up #{count} audit events older than #{@retention_days} days")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
