defmodule Manfrod.Telegram.Bot do
  @moduledoc """
  Telegram bot interface for Manfrod.
  Forwards messages to the Agent inbox asynchronously.

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
      /help - Show this help
      /idle - Close conversation and save notes
      """)
    else
      log_blocked(message, "/help")
    end
  end

  # Handle /idle command - manually trigger conversation close
  def handle({:command, "idle", message}, _context) do
    if allowed?(message) do
      Manfrod.Agent.trigger_idle(%{source: :telegram, reply_to: message.chat.id})
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

      # Send to Agent inbox - ActivityHandler will handle typing and responses
      Manfrod.Agent.send_message(%{
        content: text,
        source: :telegram,
        reply_to: message.chat.id
      })

      :ok
    else
      log_blocked(message, "text message")
    end
  end

  # Catch-all for other update types (photos, stickers, etc.)
  def handle({:update, _update}, _context) do
    :ok
  end

  defp allowed?(message) do
    message.from.id == Application.get_env(:manfrod, :telegram_allowed_user_id)
  end

  defp log_blocked(message, action) do
    Logger.warning("Blocked #{action} from unauthorized user: #{message.from.id}")
    :ok
  end
end
