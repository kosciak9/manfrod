defmodule Manfrod.Telegram.Sender do
  @moduledoc """
  Sends messages to Telegram.
  Wraps ExGram.send_message with bot token configuration.
  """

  require Logger

  alias Manfrod.Telegram.Formatter

  # Telegram message length limit
  @max_message_length 4096
  @truncation_suffix "... [truncated]"

  @doc """
  Send a text message to a Telegram chat (plain text, no formatting).
  Returns {:ok, message} or {:error, reason}.
  """
  def send(chat_id, text, opts \\ []) do
    token = Application.get_env(:manfrod, :telegram_bot_token)

    if token do
      text = truncate_message(text)
      opts = Keyword.put(opts, :token, token)
      ExGram.send_message(chat_id, text, opts)
    else
      Logger.error("Cannot send Telegram message: no bot token configured")
      {:error, :no_token}
    end
  end

  @doc """
  Send a formatted message to a Telegram chat.

  Converts markdown to Telegram HTML and sends with parse_mode: "HTML".
  Falls back to plain text if HTML parsing fails.

  Returns {:ok, message} or {:error, reason}.
  """
  def send_formatted(chat_id, text, opts \\ []) do
    token = Application.get_env(:manfrod, :telegram_bot_token)

    if token do
      html = Formatter.to_telegram_html(text)
      html = truncate_message(html)
      opts = opts |> Keyword.put(:token, token) |> Keyword.put(:parse_mode, "HTML")

      case ExGram.send_message(chat_id, html, opts) do
        {:ok, _} = success ->
          success

        {:error, %ExGram.Error{message: message}} = error ->
          if html_parse_error?(message) do
            Logger.warning(
              "Telegram HTML parse error, falling back to plain text: #{inspect(message)}"
            )

            # Fallback to plain text
            send(chat_id, text, Keyword.delete(opts, :parse_mode))
          else
            error
          end

        {:error, _} = error ->
          error
      end
    else
      Logger.error("Cannot send Telegram message: no bot token configured")
      {:error, :no_token}
    end
  end

  @doc """
  Send a silent HTML message (no notification).

  Used for system messages like conversation closing.
  Falls back to plain text if HTML parsing fails.
  """
  def send_silent(chat_id, html, opts \\ []) do
    opts = Keyword.put(opts, :disable_notification, true)
    send_html(chat_id, html, opts)
  end

  @doc """
  Send a pre-formatted HTML message (no markdown conversion).

  Use this when you've already formatted the HTML yourself (e.g., tool calls).
  Falls back to plain text if HTML parsing fails.
  """
  def send_html(chat_id, html, opts \\ []) do
    token = Application.get_env(:manfrod, :telegram_bot_token)

    if token do
      html = truncate_message(html)
      opts = opts |> Keyword.put(:token, token) |> Keyword.put(:parse_mode, "HTML")

      case ExGram.send_message(chat_id, html, opts) do
        {:ok, _} = success ->
          success

        {:error, %ExGram.Error{message: message}} = error ->
          if html_parse_error?(message) do
            Logger.warning(
              "Telegram HTML parse error, falling back to plain text: #{inspect(message)}"
            )

            # Strip HTML tags for fallback
            plain = strip_html_tags(html)
            send(chat_id, plain, Keyword.delete(opts, :parse_mode))
          else
            error
          end

        {:error, _} = error ->
          error
      end
    else
      Logger.error("Cannot send Telegram message: no bot token configured")
      {:error, :no_token}
    end
  end

  # --- Helpers ---

  defp truncate_message(text) when byte_size(text) <= @max_message_length, do: text

  defp truncate_message(text) do
    # Account for the suffix length
    max_content = @max_message_length - byte_size(@truncation_suffix)

    text
    |> String.slice(0, max_content)
    |> Kernel.<>(@truncation_suffix)
  end

  defp html_parse_error?(message) when is_binary(message) do
    String.contains?(message, "can't parse") or
      String.contains?(message, "Can't parse") or
      String.contains?(message, "Bad Request: can't parse")
  end

  defp html_parse_error?(_), do: false

  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
  end
end
