defmodule ManfrodWeb.AuditLive do
  @moduledoc """
  Live audit log of agent activity.

  Streams events in real-time, terminal-style.
  Keeps ~100kb of events in memory, drops oldest when full.
  """
  use ManfrodWeb, :live_view

  require Logger

  alias Manfrod.Events
  alias Manfrod.Events.Activity

  # ~100kb cap, rough estimate ~500 bytes per event = 200 events
  @max_events 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Logger.info("AuditLive: subscribing to events")
      Events.subscribe()
    else
      Logger.info("AuditLive: not connected yet")
    end

    {:ok, assign(socket, events: [])}
  end

  @impl true
  def handle_info({:activity, %Activity{} = activity}, socket) do
    Logger.info("AuditLive: received #{activity.type} event")

    events =
      [activity | socket.assigns.events]
      |> Enum.take(@max_events)

    {:noreply, assign(socket, events: events)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="audit-container">
        <div class="audit-header">
          <span class="audit-title">manfrod audit log</span>
          <span class="audit-status">
            <%= if @events == [] do %>
              waiting for events...
            <% else %>
              <%= length(@events) %> events
            <% end %>
          </span>
        </div>
        <div class="audit-log" id="audit-log">
          <%= for event <- @events do %>
            <div class="audit-line" id={"event-#{event.id}"}>
              <span class="ts"><%= format_time(event.timestamp) %></span>
              <span class={"type type-#{event.type}"}><%= format_type(event.type) %></span>
              <span class={"source source-#{event.source}"}><%= event.source %></span>
              <span class="detail"><%= format_detail(event) %></span>
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

      .audit-container {
        height: 100vh;
        display: flex;
        flex-direction: column;
        padding: 16px;
        font-family: 'Overpass Mono', monospace;
        font-size: 14px;
        line-height: 1.5;
        background: #1F1F28;
        color: #DCD7BA;
      }

      .audit-header {
        display: flex;
        justify-content: space-between;
        padding-bottom: 12px;
        border-bottom: 1px solid #363646;
        margin-bottom: 12px;
      }

      .audit-title {
        color: #7E9CD8;
        font-weight: 600;
      }

      .audit-status {
        color: #727169;
      }

      .audit-log {
        flex: 1;
        overflow-y: auto;
        display: flex;
        flex-direction: column;
      }

      .audit-line {
        display: flex;
        gap: 12px;
        padding: 4px 0;
        border-bottom: 1px solid #2A2A37;
      }

      .audit-line:hover {
        background: #2A2A37;
      }

      .ts {
        color: #727169;
        flex-shrink: 0;
        width: 80px;
      }

      .type {
        flex-shrink: 0;
        width: 90px;
        font-weight: 600;
      }

      .type-thinking { color: #E6C384; }
      .type-working { color: #957FB8; }
      .type-responding { color: #98BB6C; }
      .type-idle { color: #727169; }

      .source {
        flex-shrink: 0;
        width: 70px;
        color: #7FB4CA;
      }

      .detail {
        color: #C8C093;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      /* Scrollbar styling */
      .audit-log::-webkit-scrollbar {
        width: 8px;
      }

      .audit-log::-webkit-scrollbar-track {
        background: #1F1F28;
      }

      .audit-log::-webkit-scrollbar-thumb {
        background: #363646;
        border-radius: 4px;
      }

      .audit-log::-webkit-scrollbar-thumb:hover {
        background: #54546D;
      }
    </style>
    """
  end

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_type(:thinking), do: "THINKING"
  defp format_type(:working), do: "WORKING"
  defp format_type(:responding), do: "RESPOND"
  defp format_type(:idle), do: "IDLE"
  defp format_type(other), do: String.upcase(to_string(other))

  defp format_detail(%Activity{type: :working, meta: %{tool: tool}}), do: tool

  defp format_detail(%Activity{type: :responding, meta: %{content: content}}),
    do: truncate(content, 120)

  defp format_detail(%Activity{type: :idle, meta: %{exchanges: ex}}),
    do: "#{length(ex)} exchanges"

  defp format_detail(%Activity{meta: meta}) when map_size(meta) > 0, do: inspect(meta)
  defp format_detail(_), do: ""

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end

  defp truncate(str, _max), do: str
end
