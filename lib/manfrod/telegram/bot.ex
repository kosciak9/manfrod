defmodule Manfrod.Telegram.Bot do
  @moduledoc """
  Telegram bot interface for Manfrod.
  Forwards messages to the Agent inbox asynchronously.

  Only the user specified by TELEGRAM_ALLOWED_USER_ID can interact with the bot.
  """

  @bot :manfrod_telegram_bot

  use ExGram.Bot, name: @bot

  require Logger

  def bot, do: @bot

  # Handle /start command
  def handle({:command, "start", msg}, context) do
    if allowed?(msg) do
      answer(
        context,
        "Hello! I'm Manfrod, your AI assistant. Send me a message and I'll respond."
      )
    else
      log_blocked(msg, "/start")
    end
  end

  # Handle /help command
  def handle({:command, "help", msg}, context) do
    if allowed?(msg) do
      answer(context, """
      I'm Manfrod, an AI assistant.

      Just send me any message and I'll respond.

      Commands:
      /start - Start the bot
      /help - Show this help
      """)
    else
      log_blocked(msg, "/help")
    end
  end

  # Handle regular text messages
  def handle({:text, text, msg}, _context) do
    if allowed?(msg) do
      Logger.info("Telegram message received: #{String.slice(text, 0, 50)}...")

      chat_id = msg.chat.id

      on_event = fn
        {:tool_calls, calls} ->
          Manfrod.Telegram.Sender.send(chat_id, format_tool_calls(calls))

        {:error, reason} ->
          Manfrod.Telegram.Sender.send(chat_id, "⚠️ #{inspect(reason)}")

        _ ->
          :ok
      end

      # Send to Agent inbox asynchronously
      Manfrod.Agent.send_message(
        %{
          content: text,
          chat_id: chat_id,
          user_id: msg.from.id,
          source: :telegram
        },
        on_event: on_event
      )

      # No immediate response - Agent will respond via Sender
      :ok
    else
      log_blocked(msg, "text message")
    end
  end

  # Catch-all for other update types (photos, stickers, etc.)
  def handle({:update, _update}, _context) do
    :ok
  end

  defp allowed?(msg) do
    msg.from.id == Application.get_env(:manfrod, :telegram_allowed_user_id)
  end

  defp log_blocked(msg, action) do
    Logger.warning("Blocked #{action} from unauthorized user: #{msg.from.id}")
    :ok
  end

  defp format_tool_calls(calls) do
    Enum.map_join(calls, "\n", fn tc ->
      args = format_args(tc.function.arguments)
      "🔧 #{tc.function.name}(#{args})"
    end)
  end

  defp format_args(json) do
    case Jason.decode(json) do
      {:ok, map} when map == %{} ->
        ""

      {:ok, map} ->
        map
        |> Enum.map_join(", ", fn {_k, v} -> truncate(inspect(v)) end)

      _ ->
        "..."
    end
  end

  defp truncate(str) when byte_size(str) > 50 do
    String.slice(str, 0, 47) <> "..."
  end

  defp truncate(str), do: str
end
