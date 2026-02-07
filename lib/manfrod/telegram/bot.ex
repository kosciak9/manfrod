defmodule Manfrod.Telegram.Bot do
  @moduledoc """
  Telegram bot interface for Manfrod.
  Forwards messages to the Assistant inbox asynchronously.

  Only the user specified by TELEGRAM_ALLOWED_USER_ID can interact with the bot.
  """

  @bot :manfrod_telegram_bot

  use ExGram.Bot, name: @bot

  require Logger

  alias Manfrod.Events

  def bot, do: @bot

  # Handle /start command
  def handle({:command, "start", message}, context) do
    if allowed?(message) do
      answer(
        context,
        "Hello! I'm Manfrod, your AI assistant. Send me a message and I'll respond."
      )
    else
      log_blocked(message, "/start")
    end
  end

  # Handle /help command
  def handle({:command, "help", message}, context) do
    if allowed?(message) do
      answer(context, """
      I'm Manfrod, an AI assistant.

      Just send me any message and I'll respond.

      Commands:
      /start - Start the bot
      /help - Show available commands
      /idle - Clear context and save notes (auto-triggers after inactivity)
      """)
    else
      log_blocked(message, "/help")
    end
  end

  # Handle /idle command - manually trigger conversation close
  def handle({:command, "idle", message}, _context) do
    if allowed?(message) do
      Manfrod.Assistant.trigger_idle(%{source: :telegram, reply_to: message.chat.id})
      :ok
    else
      log_blocked(message, "/idle")
    end
  end

  # Handle regular text messages
  def handle({:text, text, message}, _context) do
    if allowed?(message) do
      # Broadcast message received event for activity feed
      Events.broadcast(:message_received, %{
        source: :telegram,
        meta: %{
          content: text,
          from_id: message.from.id,
          chat_id: message.chat.id,
          message_id: message.message_id
        }
      })

      # Send to Assistant inbox - ActivityHandler will handle typing and responses
      Manfrod.Assistant.send_message(%{
        content: text,
        source: :telegram,
        reply_to: message.chat.id
      })

      :ok
    else
      log_blocked(message, "text message")
    end
  end

  # Handle inline keyboard callback queries (from present_choices)
  def handle({:callback_query, callback_query}, context) do
    if allowed_callback?(callback_query) do
      # Acknowledge the button press (removes loading spinner)
      answer_callback(context, callback_query)

      chat_id = callback_query.message.chat.id
      selected_value = callback_query.data

      # Broadcast message received event
      Events.broadcast(:message_received, %{
        source: :telegram,
        meta: %{
          content: selected_value,
          from_id: callback_query.from.id,
          chat_id: chat_id,
          callback_query_id: callback_query.id
        }
      })

      # Send selected value to Assistant as a regular message
      Manfrod.Assistant.send_message(%{
        content: selected_value,
        source: :telegram,
        reply_to: chat_id
      })

      :ok
    else
      log_blocked_callback(callback_query)
    end
  end

  # Catch-all for other update types (photos, stickers, etc.)
  def handle({:update, _update}, _context) do
    :ok
  end

  defp allowed?(message) do
    message.from.id == Application.get_env(:manfrod, :telegram_allowed_user_id)
  end

  defp allowed_callback?(callback_query) do
    callback_query.from.id == Application.get_env(:manfrod, :telegram_allowed_user_id)
  end

  defp log_blocked(message, action) do
    Logger.warning("Blocked #{action} from unauthorized user: #{message.from.id}")
    :ok
  end

  defp log_blocked_callback(callback_query) do
    Logger.warning("Blocked callback query from unauthorized user: #{callback_query.from.id}")
    :ok
  end
end
