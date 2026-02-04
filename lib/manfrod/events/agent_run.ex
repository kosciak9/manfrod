defmodule Manfrod.Events.AgentRun do
  @moduledoc """
  Represents a single run of an autonomous agent (Builder or Retrospector).

  Derived from audit events - correlates start/complete/fail events into
  a coherent run with computed fields.

  ## Fields

  - `agent` - `:builder` or `:retrospector`
  - `started_at` - when the run began
  - `ended_at` - when the run ended (nil if still running)
  - `duration_ms` - computed duration in milliseconds (nil if still running)
  - `outcome` - `:success`, `:failure`, or `:running`
  - `mode` - `:task` or `:exploration` (builder only, nil for retrospector)
  - `intent` - what the agent intended to do (task description or summary)
  - `stats` - outcome statistics from completed event meta
  - `task_id` - associated task UUID (builder task mode only)
  """

  @type outcome :: :success | :failure | :running

  @type t :: %__MODULE__{
          agent: :builder | :retrospector,
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          outcome: outcome(),
          mode: :task | :exploration | nil,
          intent: String.t(),
          stats: map(),
          task_id: String.t() | nil
        }

  @enforce_keys [:agent, :started_at, :outcome, :intent]
  defstruct [
    :agent,
    :started_at,
    :ended_at,
    :duration_ms,
    :outcome,
    :mode,
    :intent,
    :stats,
    :task_id
  ]

  @doc """
  Create an AgentRun from a start event and optional end event.

  The start event must be a `builder_started` or `retrospection_started` event.
  The end event (if provided) must be the corresponding completed/failed event.
  """
  def from_events(start_event, end_event \\ nil, opts \\ [])

  def from_events(%{type: "builder_started"} = start, end_event, opts) do
    task_content = Keyword.get(opts, :task_content)
    mode_event = Keyword.get(opts, :mode_event)

    mode = get_builder_mode(mode_event)
    task_id = get_meta_field(mode_event, "task_id")

    intent =
      case mode do
        :task -> task_content || "Task execution"
        :exploration -> "Exploration session"
        nil -> "Unknown mode"
      end

    build_run(:builder, start, end_event, %{
      mode: mode,
      intent: intent,
      task_id: task_id
    })
  end

  def from_events(%{type: "retrospection_started"} = start, end_event, _opts) do
    slipbox_count = get_meta_field(start, "slipbox_count") || 0
    review_count = get_meta_field(start, "review_count") || 0

    intent = "Process #{slipbox_count} slipbox nodes, review #{review_count} graph nodes"

    build_run(:retrospector, start, end_event, %{
      mode: nil,
      intent: intent,
      task_id: nil
    })
  end

  # Helper to safely get a field from the meta map of a struct
  defp get_meta_field(nil, _field), do: nil

  defp get_meta_field(%{meta: meta}, field) when is_map(meta) do
    Map.get(meta, field)
  end

  defp get_meta_field(_, _), do: nil

  defp get_builder_mode(nil), do: nil

  defp get_builder_mode(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, "mode") do
      "task" -> :task
      "exploration" -> :exploration
      _ -> nil
    end
  end

  defp get_builder_mode(_), do: nil

  defp build_run(agent, start_event, nil, extras) do
    %__MODULE__{
      agent: agent,
      started_at: start_event.timestamp,
      ended_at: nil,
      duration_ms: nil,
      outcome: :running,
      mode: extras.mode,
      intent: extras.intent,
      stats: %{},
      task_id: extras.task_id
    }
  end

  defp build_run(agent, start_event, end_event, extras) do
    outcome =
      cond do
        String.ends_with?(end_event.type, "_completed") -> :success
        String.ends_with?(end_event.type, "_failed") -> :failure
        true -> :running
      end

    duration_ms = DateTime.diff(end_event.timestamp, start_event.timestamp, :millisecond)

    %__MODULE__{
      agent: agent,
      started_at: start_event.timestamp,
      ended_at: end_event.timestamp,
      duration_ms: duration_ms,
      outcome: outcome,
      mode: extras.mode,
      intent: extras.intent,
      stats: end_event.meta || %{},
      task_id: extras.task_id
    }
  end
end
