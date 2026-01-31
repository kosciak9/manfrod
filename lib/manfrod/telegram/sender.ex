defmodule Manfrod.Telegram.Sender do
  @moduledoc """
  Sends messages to Telegram.
  Wraps ExGram.send_message with bot token configuration.
  """

  require Logger

  @doc """
  Send a text message to a Telegram chat.
  Returns {:ok, message} or {:error, reason}.
  """
  def send(chat_id, text, opts \\ []) do
    token = Application.get_env(:manfrod, :telegram_bot_token)

    if token do
      opts = Keyword.put(opts, :token, token)
      ExGram.send_message(chat_id, text, opts)
    else
      Logger.error("Cannot send Telegram message: no bot token configured")
      {:error, :no_token}
    end
  end
end
