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
      <div class="h-screen flex flex-col font-mono text-sm bg-zinc-900 text-zinc-200">
        <%!-- Navbar --%>
        <header class="sticky top-0 z-10 bg-zinc-950 border-b border-zinc-700 px-4 py-3">
          <div class="flex justify-between items-center">
            <h1 class="text-blue-400 font-semibold text-base tracking-wide">manfrod activity</h1>
            <div class="flex items-center gap-6">
              <label class="flex items-center gap-2 text-zinc-500 cursor-pointer text-xs hover:text-zinc-300 transition-colors">
                <input
                  type="checkbox"
                  checked={@show_all_logs}
                  phx-click="toggle_all_logs"
                  class="cursor-pointer accent-blue-400"
                />
                <span>show all logs</span>
              </label>
              <span class="text-zinc-600 text-xs">
                <%= length(@events) %> events
              </span>
            </div>
          </div>
        </header>

        <%!-- Column Headers --%>
        <div class="sticky top-[53px] z-10 bg-zinc-900 border-b border-zinc-700 px-4">
          <div class="grid grid-cols-[max-content_max-content_max-content_1fr] gap-4 p-1 text-xs text-zinc-500 uppercase tracking-wider">
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
                "px-4 cursor-pointer transition-colors border-b border-zinc-800",
                row_bg_class(event),
                if(MapSet.member?(@expanded, event.id), do: "expanded")
              ]}
              id={"event-#{event.id}"}
              phx-click="toggle_expand"
              phx-value-id={event.id}
            >
              <div class="grid grid-cols-[max-content_max-content_max-content_1fr] gap-4 p-1">
                <span class="text-zinc-500 tabular-nums"><%= format_time(event.timestamp) %></span>
                <span class={["font-semibold", type_color_class(event)]}><%= format_type(event) %></span>
                <span class="text-cyan-400"><%= event.source || "-" %></span>
                <span class="text-zinc-400 truncate">
                  <%= format_detail(event) %>
                </span>
              </div>
              <%= if MapSet.member?(@expanded, event.id) and has_expandable_content?(event) do %>
                <div class="py-3 ml-[18rem] border-t border-zinc-800 bg-zinc-950/50">
                  <pre class="whitespace-pre-wrap break-all text-xs text-zinc-400 max-h-72 overflow-y-auto leading-relaxed"><%= format_expanded(event) %></pre>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Row background classes (base + hover)
  defp row_bg_class(%Activity{type: :log, meta: %{level: :error}}) do
    "bg-red-950/30 hover:bg-red-950/50"
  end

  defp row_bg_class(%Activity{type: :log, meta: %{level: :warning}}) do
    "bg-amber-950/20 hover:bg-amber-950/40"
  end

  defp row_bg_class(_event) do
    "hover:bg-zinc-800"
  end

  # Type color classes
  defp type_color_class(%Activity{type: :log, meta: %{level: :error}}), do: "text-red-500"
  defp type_color_class(%Activity{type: :log, meta: %{level: :warning}}), do: "text-amber-500"
  defp type_color_class(%Activity{type: :log, meta: %{level: :info}}), do: "text-cyan-400"
  defp type_color_class(%Activity{type: :log}), do: "text-zinc-500"
  defp type_color_class(%Activity{type: :thinking}), do: "text-yellow-400"
  defp type_color_class(%Activity{type: :narrating}), do: "text-yellow-400"
  defp type_color_class(%Activity{type: :responding}), do: "text-green-400"
  defp type_color_class(%Activity{type: :idle}), do: "text-zinc-500"
  defp type_color_class(%Activity{type: :message_received}), do: "text-cyan-400"
  defp type_color_class(%Activity{type: :action_started}), do: "text-purple-400"

  defp type_color_class(%Activity{type: :action_completed, meta: %{success: true}}),
    do: "text-green-400"

  defp type_color_class(%Activity{type: :action_completed, meta: %{success: false}}),
    do: "text-red-500"

  defp type_color_class(%Activity{type: :action_completed}), do: "text-purple-400"

  defp type_color_class(%Activity{type: type})
       when type in [
              :memory_searched,
              :memory_node_created,
              :memory_link_created,
              :memory_node_processed
            ],
       do: "text-teal-400"

  defp type_color_class(%Activity{type: type})
       when type in [
              :extraction_started,
              :extraction_completed,
              :retrospection_started,
              :retrospection_completed
            ],
       do: "text-teal-400"

  defp type_color_class(%Activity{type: type})
       when type in [:extraction_failed, :retrospection_failed],
       do: "text-red-500"

  defp type_color_class(_), do: "text-zinc-400"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  # Format type display
  defp format_type(%Activity{type: :log, meta: %{level: level}}) do
    String.upcase("#{level}")
  end

  defp format_type(%Activity{type: :message_received}), do: "MESSAGE"
  defp format_type(%Activity{type: :action_started}), do: "ACTION:START"
  defp format_type(%Activity{type: :action_completed}), do: "ACTION:DONE"
  defp format_type(%Activity{type: :thinking}), do: "THINKING"
  defp format_type(%Activity{type: :narrating}), do: "NARRATING"
  defp format_type(%Activity{type: :responding}), do: "RESPONDING"
  defp format_type(%Activity{type: :idle}), do: "IDLE"
  defp format_type(%Activity{type: :memory_searched}), do: "MEMORY:SEARCH"
  defp format_type(%Activity{type: :memory_node_created}), do: "MEMORY:CREATE"
  defp format_type(%Activity{type: :memory_link_created}), do: "MEMORY:LINK"
  defp format_type(%Activity{type: :memory_node_processed}), do: "MEMORY:PROCESS"
  defp format_type(%Activity{type: :extraction_started}), do: "EXTRACT:START"
  defp format_type(%Activity{type: :extraction_completed}), do: "EXTRACT:DONE"
  defp format_type(%Activity{type: :extraction_failed}), do: "EXTRACT:FAIL"
  defp format_type(%Activity{type: :retrospection_started}), do: "RETROSPECT:START"
  defp format_type(%Activity{type: :retrospection_completed}), do: "RETROSPECT:DONE"
  defp format_type(%Activity{type: :retrospection_failed}), do: "RETROSPECT:FAIL"
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
