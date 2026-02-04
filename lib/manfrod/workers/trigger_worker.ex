defmodule Manfrod.Workers.TriggerWorker do
  @moduledoc """
  Executes a scheduled trigger by sending a prompt to the Agent.

  All responses are routed to Telegram via the configured `telegram_allowed_user_id`.

  ## Job args

  For recurring reminders (from SchedulerWorker):
  - `recurring_reminder_id` - UUID of the recurring reminder

  For one-time reminders (from Agent):
  - `trigger_id` - identifier of the trigger (for logging)
  - `prompt` - the message to send to the Agent
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger

  alias Manfrod.Memory

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"recurring_reminder_id" => reminder_id}}) do
    Logger.info("TriggerWorker: executing recurring reminder '#{reminder_id}'")

    case Memory.get_recurring_reminder(reminder_id) do
      nil ->
        Logger.warning("TriggerWorker: recurring reminder '#{reminder_id}' not found, skipping")
        :ok

      reminder ->
        if reminder.enabled do
          prompt = build_recurring_reminder_prompt(reminder)
          send_to_agent(prompt, "recurring:#{reminder.name}")
        else
          Logger.info(
            "TriggerWorker: recurring reminder '#{reminder.name}' is disabled, skipping"
          )

          :ok
        end
    end
  end

  def perform(%Oban.Job{args: %{"prompt" => prompt, "trigger_id" => trigger_id}}) do
    Logger.info("TriggerWorker: executing one-time trigger '#{trigger_id}'")
    send_to_agent(prompt, trigger_id)
  end

  defp send_to_agent(prompt, trigger_id) do
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

  defp build_recurring_reminder_prompt(reminder) do
    node = reminder.node
    linked_nodes = Memory.get_node_links(node.id)

    linked_section =
      if linked_nodes == [] do
        ""
      else
        linked_items =
          linked_nodes
          |> Enum.map(fn n -> "- [#{n.id}] #{n.content}" end)
          |> Enum.join("\n")

        """

        ---
        Linked notes:
        #{linked_items}
        """
      end

    """
    [Recurring Reminder: #{reminder.name}]

    #{node.content}#{linked_section}
    """
    |> String.trim()
  end
end
