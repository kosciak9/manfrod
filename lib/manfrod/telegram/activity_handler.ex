defmodule Manfrod.Telegram.ActivityHandler do
  @moduledoc """
  Handles agent activity events for Telegram.

  Subscribes to the event bus and:
  - Sends typing indicators on :thinking and :working events
  - Delivers responses on :responding events
  """
  use GenServer

  require Logger

  alias Manfrod.Events
  alias Manfrod.Events.Activity
  alias Manfrod.Telegram.Sender

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Events.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:activity, %Activity{source: :telegram} = activity}, state) do
    handle_activity(activity)
    {:noreply, state}
  end

  def handle_info({:activity, %Activity{}}, state) do
    # Ignore events from other sources
    {:noreply, state}
  end

  defp handle_activity(%Activity{type: :thinking, reply_to: chat_id}) do
    send_typing(chat_id)
  end

  defp handle_activity(%Activity{type: :narrating, reply_to: chat_id, meta: %{text: text}}) do
    # Send agent's narrative/explanation text (e.g., "Let me check the source code...")
    Sender.send(chat_id, "💭 #{text}")
  end

  defp handle_activity(%Activity{type: :working, reply_to: chat_id, meta: %{tool: tool_name}}) do
    send_typing(chat_id)
    # Send tool call notification to user
    Sender.send(chat_id, "🔧 #{tool_name}")
  end

  defp handle_activity(%Activity{type: :working, reply_to: chat_id}) do
    send_typing(chat_id)
  end

  defp handle_activity(%Activity{type: :responding, reply_to: chat_id, meta: %{content: content}}) do
    case Sender.send(chat_id, content) do
      {:ok, _} ->
        Logger.info("Telegram: sent response to chat #{chat_id}")

      {:error, reason} ->
        Logger.error("Telegram: failed to send response: #{inspect(reason)}")
    end
  end

  defp handle_activity(%Activity{type: :idle}) do
    # No action needed for idle on Telegram side
    :ok
  end

  defp handle_activity(_activity) do
    :ok
  end

  defp send_typing(chat_id) do
    token = Application.get_env(:manfrod, :telegram_bot_token)

    case ExGram.send_chat_action(chat_id, "typing", token: token) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram: failed to send typing indicator: #{inspect(reason)}")
    end
  end
end
