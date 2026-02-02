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
end
