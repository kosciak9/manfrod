defmodule Manfrod.Workers.SchedulerWorker do
  @moduledoc """
  Runs hourly via Oban cron. Reads trigger definitions from `Manfrod.Triggers`
  and idempotently schedules `TriggerWorker` jobs for the next 48 hours.

  ## How it works

  1. Reads all triggers from `Manfrod.Triggers.all/0`
  2. For each trigger, calculates the next occurrences within 48 hours
  3. Inserts `TriggerWorker` jobs with Oban's uniqueness constraint
  4. Duplicate jobs (same trigger_id + scheduled_at) are skipped automatically

  ## Timezone handling

  Triggers are defined in Europe/Warsaw time. This worker converts to UTC
  when scheduling, handling DST transitions automatically.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger

  alias Manfrod.Triggers
  alias Manfrod.Workers.TriggerWorker

  @timezone "Europe/Warsaw"
  @schedule_window_hours 48

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("SchedulerWorker: scheduling triggers for next #{@schedule_window_hours} hours")

    now = DateTime.utc_now()
    triggers = Triggers.all()

    scheduled_count =
      for trigger <- triggers,
          scheduled_at <- next_occurrences(trigger.schedule, now),
          reduce: 0 do
        count ->
          args = %{
            trigger_id: Atom.to_string(trigger.id),
            prompt: trigger.prompt,
            # scheduled_at is included in args for uniqueness checking.
            # Oban's unique keys refer to args fields, not job fields.
            scheduled_at: DateTime.to_iso8601(scheduled_at)
          }

          case TriggerWorker.new(args,
                 scheduled_at: scheduled_at,
                 unique: [
                   period: @schedule_window_hours * 3600,
                   keys: [:trigger_id, :scheduled_at]
                 ]
               )
               |> Oban.insert() do
            {:ok, %{conflict?: false}} ->
              Logger.debug("SchedulerWorker: scheduled #{trigger.id} for #{scheduled_at}")
              count + 1

            {:ok, %{conflict?: true}} ->
              Logger.debug("SchedulerWorker: #{trigger.id} at #{scheduled_at} already scheduled")
              count

            {:error, reason} ->
              Logger.error(
                "SchedulerWorker: failed to schedule #{trigger.id}: #{inspect(reason)}"
              )

              count
          end
      end

    Logger.info("SchedulerWorker: scheduled #{scheduled_count} new trigger jobs")
    :ok
  end

  @doc """
  Calculates the next occurrences of a daily schedule within the scheduling window.

  Returns a list of UTC DateTimes for the trigger to fire.
  """
  @spec next_occurrences({0..23, 0..59}, DateTime.t()) :: [DateTime.t()]
  def next_occurrences({hour, minute}, now) do
    now_local = DateTime.shift_zone!(now, @timezone)
    today = DateTime.to_date(now_local)
    window_end = DateTime.add(now, @schedule_window_hours * 3600, :second)

    # Check today and next 2 days to cover 48h window
    [today, Date.add(today, 1), Date.add(today, 2)]
    |> Enum.map(fn date ->
      DateTime.new!(date, Time.new!(hour, minute, 0), @timezone)
      |> DateTime.shift_zone!("Etc/UTC")
    end)
    |> Enum.filter(fn dt ->
      DateTime.compare(dt, now) == :gt and DateTime.compare(dt, window_end) != :gt
    end)
  end
end
