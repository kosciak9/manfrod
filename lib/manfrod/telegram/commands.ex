defmodule Manfrod.Telegram.Commands do
  @moduledoc """
  Registers bot commands with Telegram API so they appear in the UI menu.
  """

  require Logger

  alias ExGram.Model.BotCommand

  @commands [
    %BotCommand{command: "start", description: "Start the bot"},
    %BotCommand{command: "help", description: "Show available commands"},
    %BotCommand{
      command: "idle",
      description: "Clear context and save notes (also happens automatically after inactivity)"
    }
  ]

  @doc """
  Registers bot commands with Telegram API.
  Called on application startup. Idempotent - safe to call multiple times.
  """
  def register do
    token = Application.get_env(:manfrod, :telegram_bot_token)

    if token do
      case ExGram.set_my_commands(@commands, token: token) do
        {:ok, true} ->
          Logger.info("Telegram bot commands registered successfully")
          :ok

        {:error, error} ->
          Logger.warning("Failed to register Telegram bot commands: #{inspect(error)}")
          {:error, error}
      end
    else
      :ok
    end
  end
end
