defmodule ManfrodWeb.SelfImprovementLive do
  @moduledoc """
  Shows Builder and Retrospector agent runs.

  Displays runs as cards with summary info. Clicking a card navigates
  to the activity view filtered to that run's time window.
  """
  use ManfrodWeb, :live_view

  alias Manfrod.Events.Store

  @impl true
  def mount(_params, _session, socket) do
    runs = Store.list_agent_runs(days: 7)

    {:ok, assign(socket, runs: runs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <Layouts.nav current={:self_improvement} />
      <div class="min-h-screen bg-zinc-900 text-zinc-200 font-mono text-sm p-6">
        <header class="text-center py-4 mb-6">
          <h1 class="text-lg font-semibold">Self-Improvement</h1>
          <p class="text-zinc-500 text-xs mt-1">Builder and Retrospector runs from the last 7 days</p>
        </header>

        <%= if @runs == [] do %>
          <div class="text-center text-zinc-500 py-12">
            No agent runs found in the last 7 days.
          </div>
        <% else %>
          <div class="max-w-3xl mx-auto space-y-3">
            <%= for run <- @runs do %>
              <.run_card run={run} />
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp run_card(assigns) do
    ~H"""
    <a
      href={activity_url(@run)}
      class="block bg-zinc-800 border border-zinc-700 rounded-lg p-4 hover:bg-zinc-750 hover:border-zinc-600 transition-colors cursor-pointer"
    >
      <div class="flex items-start justify-between gap-4">
        <%!-- Left: Agent badge and time --%>
        <div class="flex items-center gap-3">
          <.agent_badge agent={@run.agent} />
          <div>
            <div class="text-zinc-300 text-sm">
              <%= format_datetime(@run.started_at) %>
            </div>
            <%= if @run.mode do %>
              <div class="text-zinc-500 text-xs">
                <%= format_mode(@run.mode) %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Right: Outcome badge --%>
        <.outcome_badge outcome={@run.outcome} duration_ms={@run.duration_ms} />
      </div>

      <%!-- Intent --%>
      <div class="mt-3 text-zinc-400 text-sm line-clamp-2">
        <%= @run.intent %>
      </div>

      <%!-- Stats (for completed runs) --%>
      <%= if @run.outcome == :success and map_size(@run.stats) > 0 do %>
        <div class="mt-3 flex flex-wrap gap-3 text-xs text-zinc-500">
          <%= for {key, value} <- format_stats(@run) do %>
            <span><%= key %>: <span class="text-zinc-400"><%= value %></span></span>
          <% end %>
        </div>
      <% end %>
    </a>
    """
  end

  defp agent_badge(assigns) do
    {bg_class, text} =
      case assigns.agent do
        :builder -> {"bg-purple-900/50 border-purple-700", "Builder"}
        :retrospector -> {"bg-teal-900/50 border-teal-700", "Retrospector"}
      end

    assigns = assign(assigns, bg_class: bg_class, text: text)

    ~H"""
    <div class={"px-2 py-1 rounded border text-xs font-medium #{@bg_class}"}>
      <%= @text %>
    </div>
    """
  end

  defp outcome_badge(assigns) do
    {symbol, text, class} =
      case assigns.outcome do
        :success ->
          duration = format_duration(assigns.duration_ms)
          {"✓", duration, "text-green-400"}

        :failure ->
          duration = format_duration(assigns.duration_ms)
          {"✗", "Failed (#{duration})", "text-red-400"}

        :running ->
          {"⟳", "Running...", "text-amber-400 animate-pulse"}
      end

    assigns = assign(assigns, symbol: symbol, text: text, class: class)

    ~H"""
    <div class={"flex items-center gap-1.5 text-xs #{@class}"}>
      <span><%= @symbol %></span>
      <span><%= @text %></span>
    </div>
    """
  end

  # Helpers

  defp activity_url(run) do
    from_iso = DateTime.to_iso8601(run.started_at)

    # For ended runs, use ended_at + 1 second buffer
    # For running runs, use current time
    to_dt =
      case run.ended_at do
        nil -> DateTime.utc_now()
        ended -> DateTime.add(ended, 1, :second)
      end

    to_iso = DateTime.to_iso8601(to_dt)
    source = to_string(run.agent)

    "/?from=#{from_iso}&to=#{to_iso}&source=#{source}"
  end

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%b %d, %H:%M")
  end

  defp format_mode(:task), do: "Task mode"
  defp format_mode(:exploration), do: "Exploration mode"
  defp format_mode(_), do: nil

  defp format_duration(nil), do: "..."
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"

  defp format_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = rem(div(ms, 1000), 60)
    "#{minutes}m #{seconds}s"
  end

  defp format_stats(run) do
    # Builder stats
    builder_stats = [
      {"mode", run.stats["mode"]}
    ]

    # Retrospector stats
    retrospector_stats = [
      {"processed", run.stats["nodes_processed"]},
      {"links created", run.stats["links_created"]},
      {"insights", run.stats["insights_created"]},
      {"deleted", run.stats["nodes_deleted"]}
    ]

    stats =
      case run.agent do
        :builder -> builder_stats
        :retrospector -> retrospector_stats
      end

    stats
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == 0 end)
  end
end
