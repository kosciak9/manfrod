defmodule Manfrod.Events.LogHandler do
  @moduledoc """
  Custom Logger handler that captures all log events and broadcasts them
  as Activity events via PubSub.

  Captures:
  - All Logger calls (debug, info, warning, error)
  - GenServer crashes (via crash_reason metadata)
  - Supervisor reports
  - OTP/SASL reports

  Events are broadcast as `:log` type activities with level, message,
  and context in the meta field.
  """

  @behaviour :logger_handler

  alias Manfrod.Events.Activity

  @pubsub Manfrod.PubSub
  @topic "agent:activity"

  # Required callback - handles each log event
  @impl true
  def log(%{level: level, msg: log_message, meta: meta}, _config) do
    # Skip logs that would cause infinite loops
    if should_skip?(meta, log_message) do
      :ok
    else
      activity = build_activity(level, log_message, meta)
      broadcast(activity)
    end
  end

  # Called when handler is added
  @impl true
  def adding_handler(config) do
    {:ok, config}
  end

  # Called when handler is removed
  @impl true
  def removing_handler(_config) do
    :ok
  end

  # Called when config changes
  @impl true
  def changing_config(:set, _old_config, new_config) do
    {:ok, new_config}
  end

  def changing_config(:update, old_config, new_config) do
    {:ok, Map.merge(old_config, new_config)}
  end

  # --- Private Functions ---

  defp should_skip?(meta, log_message) do
    # Skip logs from internal modules
    skip_by_module?(meta) or skip_audit_events_query?(log_message)
  end

  defp skip_by_module?(meta) do
    case meta[:mfa] do
      # Internal event handling - would cause loops
      {Phoenix.PubSub, _, _} -> true
      {Phoenix.Channel.Server, _, _} -> true
      {Manfrod.Events.LogHandler, _, _} -> true
      {Manfrod.Events.Persister, _, _} -> true
      {Manfrod.Events.Store, _, _} -> true
      _ -> false
    end
  end

  # Skip Ecto queries on audit_events table to prevent infinite loop
  defp skip_audit_events_query?({:string, chardata}) do
    log_message = IO.chardata_to_string(chardata)
    String.contains?(log_message, "audit_events")
  end

  defp skip_audit_events_query?({:report, %{query: query}}) when is_binary(query) do
    String.contains?(query, "audit_events")
  end

  defp skip_audit_events_query?(_), do: false

  defp build_activity(level, log_message, meta) do
    %Activity{
      id: generate_id(),
      type: :log,
      source: :logger,
      reply_to: nil,
      meta: %{
        level: level,
        message: format_message(log_message),
        module: extract_module(meta),
        function: extract_function(meta),
        file: meta[:file],
        line: meta[:line],
        pid: inspect_pid(meta[:pid]),
        crash_reason: extract_crash_reason(meta),
        stacktrace: extract_stacktrace(meta),
        domain: meta[:domain]
      },
      timestamp: DateTime.utc_now()
    }
  end

  defp format_message({:string, chardata}) do
    IO.chardata_to_string(chardata) |> truncate(2000)
  end

  defp format_message({:report, report}) do
    inspect(report, pretty: true, limit: 50) |> truncate(2000)
  end

  defp format_message({format, args}) when is_list(args) do
    try do
      :io_lib.format(format, args) |> IO.chardata_to_string() |> truncate(2000)
    rescue
      _ -> "Format error: #{inspect(format)}"
    end
  end

  defp format_message(other) do
    inspect(other, limit: 50) |> truncate(2000)
  end

  defp extract_module(%{mfa: {module, _, _}}), do: module
  defp extract_module(_), do: nil

  defp extract_function(%{mfa: {_, function, arity}}), do: "#{function}/#{arity}"
  defp extract_function(_), do: nil

  defp inspect_pid(nil), do: nil
  defp inspect_pid(pid), do: inspect(pid)

  defp extract_crash_reason(%{crash_reason: {reason, _stacktrace}}) do
    format_reason(reason)
  end

  defp extract_crash_reason(_), do: nil

  defp format_reason({:nocatch, term}), do: "throw: #{inspect(term, limit: 20)}"

  defp format_reason(%{__exception__: true} = exception) do
    Exception.message(exception) |> truncate(500)
  end

  defp format_reason(exit_reason), do: "exit: #{inspect(exit_reason, limit: 20)}"

  defp extract_stacktrace(%{crash_reason: {_reason, stacktrace}}) do
    Exception.format_stacktrace(stacktrace) |> truncate(2000)
  end

  defp extract_stacktrace(_), do: nil

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end

  defp truncate(str, _max), do: str

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp broadcast(activity) do
    # Only broadcast if PubSub is running
    if Process.whereis(@pubsub) do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:activity, activity})
    end
  end
end
