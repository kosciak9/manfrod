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
      },
      %{
        id: :self_improvement,
        schedule: {4, 0},
        prompt: """
        Self-improvement retrospective. Follow these steps:

        1. FETCH RECENT CONVERSATIONS
           Use eval_code: Manfrod.Memory.get_recent_conversations(24)
           This returns conversations from the last 24 hours with their messages.

        2. ANALYZE
           Review the conversations. Look for:
           - Questions you couldn't answer well
           - Tasks that took too long or failed
           - Patterns in user requests you could handle better
           - Knowledge gaps
           - Tool limitations

        3. RESEARCH
           For each improvement area, use run_shell with curl to research solutions.
           Example: curl -s "https://html.duckduckgo.com/html/?q=your+query" | grep -oP '(?<=<a rel="nofollow" class="result__a" href=")[^"]*' | head -5

           If curl isn't sufficient for research, that's your first improvement opportunity - you can install better tools (lynx, w3m, ddgr, etc.).

        4. PRESENT
           Share your findings clearly:
           - What you reviewed (conversation summaries)
           - Key improvement areas identified
           - Research findings with sources
           - Concrete next steps you'll take

        Be specific and actionable. Focus on 2-3 high-impact improvements.
        Your insights from this conversation will be automatically extracted and stored in your knowledge graph.
        """
      }
    ]
  end
end
