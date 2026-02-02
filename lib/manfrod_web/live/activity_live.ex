defmodule ManfrodWeb.ActivityLive do
  @moduledoc """
  Live activity feed for full assistant observability.

  Shows all events in real-time: messages, actions, logs, memory ops.
  Streams events terminal-style. Keeps ~200 events in memory.

  Filters:
  - Log levels: warning+ by default, toggle to show info/debug
  - Event types: all shown by default
  """
  use ManfrodWeb, :live_view

  alias Manfrod.Events
  alias Manfrod.Events.Activity
  alias Manfrod.Events.Store

  @max_events 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe()
    end

    # Load persisted events on mount (warning+ logs only by default)
    events = Store.list_recent_filtered(@max_events, include_all_logs: false)

    socket =
      socket
      |> assign(events: events)
      |> assign(show_all_logs: false)
      |> assign(expanded: MapSet.new())

    {:ok, socket}
  end

  @impl true
  def handle_info({:activity, %Activity{} = activity}, socket) do
    # Filter incoming logs based on current setting
    should_show =
      if activity.type == :log do
        socket.assigns.show_all_logs or
          activity.meta[:level] in [:warning, :error]
      else
        true
      end

    socket =
      if should_show do
        events =
          [activity | socket.assigns.events]
          |> Enum.take(@max_events)

        assign(socket, events: events)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_all_logs", _, socket) do
    show_all_logs = !socket.assigns.show_all_logs

    # Reload events with new filter
    events = Store.list_recent_filtered(@max_events, include_all_logs: show_all_logs)

    {:noreply, assign(socket, show_all_logs: show_all_logs, events: events)}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, id) do
        MapSet.delete(socket.assigns.expanded, id)
      else
        MapSet.put(socket.assigns.expanded, id)
      end

    {:noreply, assign(socket, expanded: expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="h-screen flex flex-col font-mono text-sm bg-[#1F1F28] text-[#DCD7BA]">
        <%!-- Navbar --%>
        <header class="sticky top-0 z-10 bg-[#16161D] border-b border-[#363646] px-4 py-3">
          <div class="flex justify-between items-center">
            <h1 class="text-[#7E9CD8] font-semibold text-base tracking-wide">manfrod activity</h1>
            <div class="flex items-center gap-6">
              <label class="flex items-center gap-2 text-[#727169] cursor-pointer text-xs hover:text-[#DCD7BA] transition-colors">
                <input
                  type="checkbox"
                  checked={@show_all_logs}
                  phx-click="toggle_all_logs"
                  class="cursor-pointer accent-[#7E9CD8]"
                />
                <span>show all logs</span>
              </label>
              <span class="text-[#54546D] text-xs">
                <%= length(@events) %> events
              </span>
            </div>
          </div>
        </header>

        <%!-- Column Headers --%>
        <div class="sticky top-[53px] z-10 bg-[#1F1F28] border-b border-[#363646] px-4">
          <div class="grid grid-cols-[70px_90px_80px_minmax(0,1fr)] gap-4 py-2 text-xs text-[#54546D] uppercase tracking-wider">
            <span>Time</span>
            <span>Type</span>
            <span>Source</span>
            <span>Details</span>
          </div>
        </div>

        <%!-- Event List --%>
        <div class="flex-1 overflow-y-auto" id="activity-log">
          <%= for event <- @events do %>
            <div
              class={[
                "event-row px-4 cursor-pointer transition-colors",
                type_class(event),
                if(MapSet.member?(@expanded, event.id), do: "expanded")
              ]}
              id={"event-#{event.id}"}
              phx-click="toggle_expand"
              phx-value-id={event.id}
            >
              <div class="grid grid-cols-[70px_90px_80px_minmax(0,1fr)] gap-4 py-2 border-b border-[#2A2A37]">
                <span class="text-[#727169] tabular-nums"><%= format_time(event.timestamp) %></span>
                <span class={"font-semibold #{type_class(event)}"}><%= format_type(event) %></span>
                <span class="text-[#7FB4CA]"><%= event.source || "-" %></span>
                <span class="text-[#C8C093] overflow-hidden text-ellipsis whitespace-nowrap min-w-0">
                  <%= format_detail(event) %>
                </span>
              </div>
              <%= if MapSet.member?(@expanded, event.id) and has_expandable_content?(event) do %>
                <div class="py-3 pl-[166px] border-b border-[#2A2A37] bg-[#1A1A22]">
                  <pre class="m-0 whitespace-pre-wrap break-all text-xs text-[#C8C093] max-h-[300px] overflow-y-auto leading-relaxed"><%= format_expanded(event) %></pre>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>

    <style>
      @import url('https://fonts.googleapis.com/css2?family=Overpass+Mono:wght@400;600&display=swap');

      body {
        background: #1F1F28 !important;
        color: #DCD7BA !important;
        font-family: 'Overpass Mono', monospace !important;
      }

      main {
        max-width: none !important;
        padding: 0 !important;
      }

      /* Row hover */
      .event-row:hover { background: #2A2A37; }
      .event-row.type-log-error:hover { background: rgba(232, 36, 36, 0.15); }
      .event-row.type-log-warning:hover { background: rgba(255, 158, 59, 0.1); }

      /* Event type colors */
      .type-thinking, .type-narrating { color: #E6C384; }
      .type-responding { color: #98BB6C; }
      .type-idle { color: #727169; }
      .type-message_received { color: #7FB4CA; }
      .type-action_started, .type-action_completed { color: #957FB8; }
      .type-action_completed.success { color: #98BB6C; }
      .type-action_completed.failure { color: #E82424; }
      .type-log, .type-log-debug { color: #727169; }
      .type-log-info { color: #7FB4CA; }
      .type-log-warning { color: #FF9E3B; }
      .type-log-error { color: #E82424; }
      .type-memory_searched, .type-memory_node_created,
      .type-memory_link_created, .type-memory_node_processed,
      .type-extraction_started, .type-extraction_completed,
      .type-retrospection_started, .type-retrospection_completed { color: #7AA89F; }
      .type-extraction_failed, .type-retrospection_failed { color: #E82424; }

      /* Error/warning line highlights */
      .event-row.type-log-error { background: rgba(232, 36, 36, 0.1); }
      .event-row.type-log-warning { background: rgba(255, 158, 59, 0.05); }
    </style>
    """
  end

  # Type class for CSS styling
  defp type_class(%Activity{type: :log, meta: %{level: level}}) do
    "type-log-#{level}"
  end

  defp type_class(%Activity{type: :action_completed, meta: %{success: true}}) do
    "type-action_completed success"
  end

  defp type_class(%Activity{type: :action_completed, meta: %{success: false}}) do
    "type-action_completed failure"
  end

  defp type_class(%Activity{type: type}) do
    "type-#{type}"
  end

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  # Format type display
  defp format_type(%Activity{type: :log, meta: %{level: level}}) do
    String.upcase("#{level}")
  end

  defp format_type(%Activity{type: :message_received}), do: "MSG"
  defp format_type(%Activity{type: :action_started}), do: "ACTION"
  defp format_type(%Activity{type: :action_completed}), do: "DONE"
  defp format_type(%Activity{type: :thinking}), do: "THINKING"
  defp format_type(%Activity{type: :narrating}), do: "NARRATE"
  defp format_type(%Activity{type: :responding}), do: "RESPOND"
  defp format_type(%Activity{type: :idle}), do: "IDLE"
  defp format_type(%Activity{type: :memory_searched}), do: "MEM:SRCH"
  defp format_type(%Activity{type: :memory_node_created}), do: "MEM:NEW"
  defp format_type(%Activity{type: :memory_link_created}), do: "MEM:LINK"
  defp format_type(%Activity{type: :memory_node_processed}), do: "MEM:PROC"
  defp format_type(%Activity{type: :extraction_started}), do: "EXTRACT"
  defp format_type(%Activity{type: :extraction_completed}), do: "EXTRACT"
  defp format_type(%Activity{type: :extraction_failed}), do: "EXTRACT!"
  defp format_type(%Activity{type: :retrospection_started}), do: "RETRO"
  defp format_type(%Activity{type: :retrospection_completed}), do: "RETRO"
  defp format_type(%Activity{type: :retrospection_failed}), do: "RETRO!"
  defp format_type(%Activity{type: type}), do: String.upcase(to_string(type))

  # Format detail (one-line summary)
  defp format_detail(%Activity{type: :message_received, meta: %{content: content}}) do
    truncate(content, 100)
  end

  defp format_detail(%Activity{type: :action_started, meta: %{action: action, args: args}}) do
    "#{action} #{truncate(args, 80)}"
  end

  defp format_detail(%Activity{type: :action_completed, meta: meta}) do
    duration = Map.get(meta, :duration_ms, 0)
    result_preview = truncate(Map.get(meta, :result, ""), 60)
    "#{duration}ms #{result_preview}"
  end

  defp format_detail(%Activity{type: :log, meta: %{message: message}}) do
    truncate(message, 120)
  end

  defp format_detail(%Activity{type: :narrating, meta: %{text: text}}) do
    truncate(text, 120)
  end

  defp format_detail(%Activity{type: :responding, meta: %{content: content}}) do
    truncate(content, 120)
  end

  defp format_detail(%Activity{type: :idle}), do: "conversation timeout"

  defp format_detail(%Activity{meta: meta}) when map_size(meta) > 0 do
    inspect(meta, limit: 5)
  end

  defp format_detail(_), do: ""

  # Check if event has expandable content
  defp has_expandable_content?(%Activity{type: :action_started}), do: true
  defp has_expandable_content?(%Activity{type: :action_completed}), do: true

  defp has_expandable_content?(%Activity{type: :log, meta: %{stacktrace: stacktrace}})
       when stacktrace != "" and not is_nil(stacktrace),
       do: true

  defp has_expandable_content?(%Activity{type: :log, meta: %{message: message}})
       when is_binary(message) and byte_size(message) > 100,
       do: true

  defp has_expandable_content?(%Activity{type: :log, meta: %{message: message}})
       when is_list(message) and length(message) > 100,
       do: true

  defp has_expandable_content?(%Activity{type: :message_received}), do: true
  defp has_expandable_content?(%Activity{type: :responding}), do: true
  defp has_expandable_content?(%Activity{type: :narrating}), do: true
  defp has_expandable_content?(_), do: false

  # Format expanded content
  defp format_expanded(%Activity{type: :action_started, meta: meta}) do
    """
    Action: #{meta[:action]}
    Args: #{format_json(meta[:args])}
    """
  end

  defp format_expanded(%Activity{type: :action_completed, meta: meta}) do
    base = """
    Duration: #{meta[:duration_ms]}ms
    Success: #{meta[:success]}
    Result:
    #{meta[:result]}
    """

    base
  end

  defp format_expanded(%Activity{type: :log, meta: meta}) do
    parts = [
      "Message: #{meta[:message]}",
      if(meta[:module], do: "Module: #{inspect(meta[:module])}"),
      if(meta[:function], do: "Function: #{meta[:function]}"),
      if(meta[:file], do: "File: #{meta[:file]}:#{meta[:line]}"),
      if(meta[:crash_reason], do: "\nCrash Reason: #{meta[:crash_reason]}"),
      if(meta[:stacktrace], do: "\nStacktrace:\n#{meta[:stacktrace]}")
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_expanded(%Activity{type: :message_received, meta: meta}) do
    """
    Content: #{meta[:content]}
    From: #{meta[:from_id]}
    Chat: #{meta[:chat_id]}
    """
  end

  defp format_expanded(%Activity{type: :responding, meta: %{content: content}}) do
    content
  end

  defp format_expanded(%Activity{type: :narrating, meta: %{text: text}}) do
    text
  end

  defp format_expanded(%Activity{meta: meta}) do
    inspect(meta, pretty: true, limit: :infinity)
  end

  defp format_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> json
    end
  end

  defp format_json(other), do: inspect(other, pretty: true)

  defp truncate(nil, _max), do: ""

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end

  defp truncate(str, _max) when is_binary(str), do: str
  defp truncate(other, max), do: truncate(inspect(other), max)
end
