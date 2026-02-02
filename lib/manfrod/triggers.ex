defmodule Manfrod.Triggers do
  @moduledoc """
  Scheduled trigger definitions.

  Edit this module to add, remove, or modify triggers.
  The SchedulerWorker reads this hourly and schedules jobs accordingly.

  ## Trigger format

  Each trigger is a map with:
  - `id` - unique atom identifier
  - `schedule` - `{hour, minute}` tuple in Europe/Warsaw timezone
  - `prompt` - the message to send to the Agent

  ## Adding a new trigger

  Add a new map to the list returned by `all/0`:

      %{
        id: :evening_review,
        schedule: {22, 0},
        prompt: "Evening review: What did I accomplish today?"
      }

  The SchedulerWorker will pick up changes on its next hourly run.
  """

  @type trigger :: %{
          id: atom(),
          schedule: {hour :: 0..23, minute :: 0..59},
          prompt: String.t()
        }

  @doc """
  Returns all configured triggers.
  """
  @spec all() :: [trigger()]
  def all do
    [
      %{
        id: :morning_brief,
        schedule: {8, 0},
        prompt:
          "Morning brief: What's important for me to know today? Summarize recent conversations and any relevant memories."
      }
    ]
  end
end
