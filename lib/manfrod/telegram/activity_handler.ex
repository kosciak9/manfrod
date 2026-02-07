defmodule Manfrod.Telegram.ActivityHandler do
  @moduledoc """
  Handles agent activity events for Telegram.

  Subscribes to the event bus and:
  - Sends typing indicators on :thinking and :action_started events
  - Delivers responses on :responding events
  """
  use GenServer

  require Logger

  alias Manfrod.Events
  alias Manfrod.Events.Activity
  alias Manfrod.Telegram.Formatter
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
    Sender.send_formatted(chat_id, "💭 #{text}")
  end

  defp handle_activity(%Activity{
         type: :action_started,
         reply_to: chat_id,
         meta: %{action: action_name, args: args}
       }) do
    send_typing(chat_id)
    # Send action notification with args formatted as code
    html = "🔧 " <> Formatter.format_tool_call(action_name, args)
    Sender.send_silent(chat_id, html)
  end

  defp handle_activity(%Activity{type: :action_started, reply_to: chat_id}) do
    send_typing(chat_id)
  end

  defp handle_activity(%Activity{
         type: :presenting_choices,
         reply_to: chat_id,
         meta: %{question: question, choices: choices}
       }) do
    # Build inline keyboard - one button per row
    keyboard =
      ExGram.Dsl.create_inline(
        Enum.map(choices, fn %{label: label, value: value} ->
          [[text: label, callback_data: value]]
        end)
      )

    token = Application.get_env(:manfrod, :telegram_bot_token)

    case ExGram.send_message(chat_id, question,
           reply_markup: keyboard,
           token: token
         ) do
      {:ok, _} ->
        Logger.info("Telegram: sent inline keyboard to chat #{chat_id}")

      {:error, reason} ->
        Logger.error("Telegram: failed to send inline keyboard: #{inspect(reason)}")
        # Fallback: send as plain text with labeled options
        fallback =
          question <>
            "\n\n" <>
            Enum.map_join(choices, "\n", fn %{label: label, value: value} ->
              "• #{label} (reply: #{value})"
            end)

        Sender.send_formatted(chat_id, fallback)
    end
  end

  defp handle_activity(%Activity{type: :action_completed}) do
    # No notification needed for action completion
    :ok
  end

  defp handle_activity(%Activity{type: :responding, reply_to: chat_id, meta: %{content: content}}) do
    case Sender.send_formatted(chat_id, content) do
      {:ok, _} ->
        Logger.info("Telegram: sent response to chat #{chat_id}")

      {:error, reason} ->
        Logger.error("Telegram: failed to send response: #{inspect(reason)}")
    end
  end

  defp handle_activity(%Activity{type: :idle, reply_to: chat_id}) do
    # Send a silent italic message indicating conversation is closing
    Sender.send_silent(chat_id, "<i>closing the conversation and writing down notes...</i>")
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
