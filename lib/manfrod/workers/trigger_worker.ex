defmodule Manfrod.Workers.TriggerWorker do
  @moduledoc """
  Executes a scheduled trigger by sending a prompt to the Agent.

  All responses are routed to Telegram via the configured `telegram_allowed_user_id`.

  ## Job args

  - `trigger_id` - identifier of the trigger (for logging)
  - `prompt` - the message to send to the Agent
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"prompt" => prompt, "trigger_id" => trigger_id}}) do
    Logger.info("TriggerWorker: executing trigger '#{trigger_id}'")

    chat_id = Application.get_env(:manfrod, :telegram_allowed_user_id)

    if is_nil(chat_id) do
      Logger.error("TriggerWorker: telegram_allowed_user_id not configured")
      {:error, :missing_chat_id}
    else
      Manfrod.Agent.send_message(%{
        content: prompt,
        source: :telegram,
        reply_to: chat_id
      })

      Logger.info("TriggerWorker: trigger '#{trigger_id}' sent to Agent")
      :ok
    end
  end
end
