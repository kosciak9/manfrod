defmodule Manfrod.Events.Store do
  @moduledoc """
  Persistence layer for audit events.

  Provides functions to insert, query, and clean up audit events.
  """

  import Ecto.Query

  alias Manfrod.Repo
  alias Manfrod.Events.Activity
  alias Manfrod.Events.AuditEvent

  @doc """
  Insert an Activity into the audit log.

  Returns `{:ok, audit_event}` or `{:error, changeset}`.
  """
  def insert(%Activity{} = activity) do
    activity
    |> AuditEvent.changeset_from_activity()
    |> Repo.insert()
  end

  @doc """
  Get audit events since a given timestamp, ordered chronologically.

  Options:
  - `:limit` - max events to return (default: 100)
  - `:types` - list of event types to filter (default: all)

  Returns a list of Activity structs.
  """
  def get_events_since(timestamp, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    types = Keyword.get(opts, :types, nil)

    query =
      AuditEvent
      |> where([e], e.timestamp > ^timestamp)
      |> order_by([e], asc: e.timestamp)
      |> limit(^limit)

    query =
      if types do
        type_strings = Enum.map(types, &to_string/1)
        where(query, [e], e.type in ^type_strings)
      else
        query
      end

    query
    |> Repo.all()
    |> Enum.map(&AuditEvent.to_activity/1)
  end

  @doc """
  List recent audit events, ordered by timestamp descending.

  Returns a list of Activity structs for compatibility with AuditLive.
  """
  def list_recent(limit \\ 200) do
    AuditEvent
    |> order_by([e], desc: e.timestamp)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&AuditEvent.to_activity/1)
  end

  @doc """
  List recent audit events, excluding debug/info logs by default.
  Pass `include_all_logs: true` to include all log levels.

  Returns a list of Activity structs for compatibility with ActivityLive.
  """
  def list_recent_filtered(limit \\ 200, opts \\ []) do
    include_all_logs = Keyword.get(opts, :include_all_logs, false)

    query =
      AuditEvent
      |> order_by([e], desc: e.timestamp)
      |> limit(^limit)

    query =
      if include_all_logs do
        query
      else
        # Exclude debug/info logs, keep warning/error logs and all other event types
        where(
          query,
          [e],
          e.type != "log" or
            fragment("(?->>'level')::text", e.meta) in ["warning", "error"]
        )
      end

    query
    |> Repo.all()
    |> Enum.map(&AuditEvent.to_activity/1)
  end

  @doc """
  Delete audit events older than the specified number of days.

  Returns `{count, nil}` where count is the number of deleted rows.
  """
  def delete_older_than(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    AuditEvent
    |> where([e], e.timestamp < ^cutoff)
    |> Repo.delete_all()
  end

  @doc """
  Delete log events older than the specified number of hours.
  Logs have shorter retention than other events.

  Returns `{count, nil}` where count is the number of deleted rows.
  """
  def delete_logs_older_than(hours) when is_integer(hours) and hours > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -hours, :hour)

    AuditEvent
    |> where([e], e.type == "log" and e.timestamp < ^cutoff)
    |> Repo.delete_all()
  end

  @doc """
  Aggregate LLM metrics for the last N days.

  Returns a map with daily breakdowns and totals:
  - `:daily` - list of maps per day with counts
  - `:totals` - aggregate totals across all days

  Each daily entry contains:
  - `:date` - the date
  - `:free_calls` - LLM calls to free tier
  - `:paid_calls` - LLM calls to paid tier
  - `:retries` - retry events
  - `:fallbacks` - fallback events
  - `:input_tokens` - total input tokens
  - `:output_tokens` - total output tokens
  - `:messages_received` - user messages
  - `:messages_sent` - assistant responses
  - `:tool_calls` - action_started events
  """
  def aggregate_llm_metrics(days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    # Query all relevant events in the time range
    events =
      AuditEvent
      |> where([e], e.timestamp >= ^cutoff)
      |> where(
        [e],
        e.type in [
          "llm_call_succeeded",
          "llm_retry",
          "llm_fallback",
          "message_received",
          "responding",
          "action_started"
        ]
      )
      |> Repo.all()

    # Group by date and aggregate
    daily =
      events
      |> Enum.group_by(fn e -> DateTime.to_date(e.timestamp) end)
      |> Enum.map(fn {date, day_events} ->
        %{
          date: date,
          free_calls: count_by_type_and_tier(day_events, "llm_call_succeeded", "free"),
          paid_calls: count_by_type_and_tier(day_events, "llm_call_succeeded", "paid"),
          retries: count_by_type(day_events, "llm_retry"),
          fallbacks: count_by_type(day_events, "llm_fallback"),
          input_tokens: sum_meta_field(day_events, "llm_call_succeeded", "input_tokens"),
          output_tokens: sum_meta_field(day_events, "llm_call_succeeded", "output_tokens"),
          messages_received: count_by_type(day_events, "message_received"),
          messages_sent: count_by_type(day_events, "responding"),
          tool_calls: count_by_type(day_events, "action_started")
        }
      end)
      |> Enum.sort_by(& &1.date, Date)

    # Fill in missing days with zeros
    daily = fill_missing_days(daily, days)

    # Calculate totals
    totals = %{
      free_calls: Enum.sum(Enum.map(daily, & &1.free_calls)),
      paid_calls: Enum.sum(Enum.map(daily, & &1.paid_calls)),
      retries: Enum.sum(Enum.map(daily, & &1.retries)),
      fallbacks: Enum.sum(Enum.map(daily, & &1.fallbacks)),
      input_tokens: Enum.sum(Enum.map(daily, & &1.input_tokens)),
      output_tokens: Enum.sum(Enum.map(daily, & &1.output_tokens)),
      messages_received: Enum.sum(Enum.map(daily, & &1.messages_received)),
      messages_sent: Enum.sum(Enum.map(daily, & &1.messages_sent)),
      tool_calls: Enum.sum(Enum.map(daily, & &1.tool_calls))
    }

    %{daily: daily, totals: totals}
  end

  defp count_by_type(events, type) do
    Enum.count(events, &(&1.type == type))
  end

  defp count_by_type_and_tier(events, type, tier) do
    tier_str = to_string(tier)

    Enum.count(events, fn e ->
      e.type == type and get_in(e.meta, ["tier"]) == tier_str
    end)
  end

  defp sum_meta_field(events, type, field) do
    events
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(fn e -> get_in(e.meta, [field]) || 0 end)
    |> Enum.sum()
  end

  defp fill_missing_days(daily, num_days) do
    today = Date.utc_today()
    all_dates = for i <- (num_days - 1)..0, do: Date.add(today, -i)

    existing_dates = MapSet.new(daily, & &1.date)

    missing =
      all_dates
      |> Enum.reject(&MapSet.member?(existing_dates, &1))
      |> Enum.map(fn date ->
        %{
          date: date,
          free_calls: 0,
          paid_calls: 0,
          retries: 0,
          fallbacks: 0,
          input_tokens: 0,
          output_tokens: 0,
          messages_received: 0,
          messages_sent: 0,
          tool_calls: 0
        }
      end)

    (daily ++ missing)
    |> Enum.sort_by(& &1.date, Date)
  end
end
