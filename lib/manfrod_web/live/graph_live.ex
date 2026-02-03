defmodule ManfrodWeb.GraphLive do
  @moduledoc """
  Graph visualization for the zettelkasten.

  Displays nodes and links in an interactive force-directed graph.
  Features:
  - Click node to view details in side panel
  - Search to highlight matching nodes
  - Filter by status (all / processed / slipbox)
  - Initial view centers on the "soul" (first node)
  """
  use ManfrodWeb, :live_view

  alias Manfrod.Memory

  @impl true
  def mount(_params, _session, socket) do
    graph_data = Memory.get_graph_data()
    soul = Memory.get_soul()

    socket =
      socket
      |> assign(graph_data: graph_data)
      |> assign(soul_id: soul && soul.id)
      |> assign(selected_node: nil)
      |> assign(filter: :all)
      |> assign(search_query: "")
      |> assign(search_results: [])

    {:ok, socket}
  end

  @impl true
  def handle_event("node_clicked", %{"id" => node_id}, socket) do
    node = Memory.get_node(node_id)
    links = Memory.get_node_links(node_id)

    selected =
      if node do
        %{
          id: node.id,
          content: node.content,
          processed: not is_nil(node.processed_at),
          link_count: length(links),
          inserted_at: node.inserted_at,
          links:
            Enum.map(links, fn n -> %{id: n.id, preview: String.slice(n.content || "", 0, 50)} end)
        }
      else
        nil
      end

    {:noreply, assign(socket, selected_node: selected)}
  end

  def handle_event("node_deselected", _params, socket) do
    {:noreply, assign(socket, selected_node: nil)}
  end

  def handle_event("search", %{"query" => query}, socket) when byte_size(query) < 3 do
    socket =
      socket
      |> assign(search_query: query)
      |> assign(search_results: [])
      |> push_event("clear_highlight", %{})

    {:noreply, socket}
  end

  def handle_event("search", %{"query" => query}, socket) do
    case Memory.search(query, limit: 20, expand_query: false) do
      {:ok, nodes} when nodes != [] ->
        ids = Enum.map(nodes, & &1.id)
        first_id = List.first(ids)

        socket =
          socket
          |> assign(search_query: query)
          |> assign(search_results: nodes)
          |> push_event("highlight_nodes", %{ids: ids, center_on: first_id})

        {:noreply, socket}

      _ ->
        socket =
          socket
          |> assign(search_query: query)
          |> assign(search_results: [])
          |> push_event("clear_highlight", %{})

        {:noreply, socket}
    end
  end

  def handle_event("clear_search", _params, socket) do
    socket =
      socket
      |> assign(search_query: "")
      |> assign(search_results: [])
      |> push_event("clear_highlight", %{})

    {:noreply, socket}
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter_atom = String.to_existing_atom(filter)
    graph_data = Memory.get_graph_data(filter: filter_atom)

    socket =
      socket
      |> assign(filter: filter_atom)
      |> assign(graph_data: graph_data)
      |> push_event("update_graph", graph_data)

    {:noreply, socket}
  end

  def handle_event("select_linked_node", %{"id" => node_id}, socket) do
    # Select a linked node from the panel
    node = Memory.get_node(node_id)
    links = Memory.get_node_links(node_id)

    selected =
      if node do
        %{
          id: node.id,
          content: node.content,
          processed: not is_nil(node.processed_at),
          link_count: length(links),
          inserted_at: node.inserted_at,
          links:
            Enum.map(links, fn n -> %{id: n.id, preview: String.slice(n.content || "", 0, 50)} end)
        }
      else
        nil
      end

    socket =
      socket
      |> assign(selected_node: selected)
      |> push_event("highlight_nodes", %{ids: [node_id], center_on: node_id})

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <Layouts.nav current={:graph} />
      <div class="h-[calc(100vh-60px)] flex flex-col font-mono text-sm bg-zinc-900 text-zinc-200">
        <%!-- Header with search and filters --%>
        <header class="sticky top-0 z-10 bg-zinc-950 border-b border-zinc-700 px-4 py-3">
          <div class="flex items-center gap-4">
            <%!-- Search --%>
            <form phx-submit="search" phx-change="search" class="flex-1 max-w-md">
              <div class="relative">
                <input
                  type="text"
                  name="query"
                  value={@search_query}
                  placeholder="Search nodes..."
                  phx-debounce="300"
                  class="w-full bg-zinc-800 border border-zinc-700 rounded px-3 py-1.5 text-sm text-zinc-200 placeholder-zinc-500 focus:outline-none focus:border-blue-500"
                />
                <%= if @search_query != "" do %>
                  <button
                    type="button"
                    phx-click="clear_search"
                    class="absolute right-2 top-1/2 -translate-y-1/2 text-zinc-500 hover:text-zinc-300 text-lg leading-none"
                  >
                    &times;
                  </button>
                <% end %>
              </div>
            </form>

            <%!-- Filters --%>
            <div class="flex items-center gap-2 text-xs">
              <span class="text-zinc-500">Filter:</span>
              <button
                phx-click="set_filter"
                phx-value-filter="all"
                class={[
                  "px-2 py-1 rounded transition-colors",
                  @filter == :all && "bg-blue-600 text-white",
                  @filter != :all && "bg-zinc-800 text-zinc-400 hover:bg-zinc-700"
                ]}
              >
                all
              </button>
              <button
                phx-click="set_filter"
                phx-value-filter="processed"
                class={[
                  "px-2 py-1 rounded transition-colors",
                  @filter == :processed && "bg-teal-600 text-white",
                  @filter != :processed && "bg-zinc-800 text-zinc-400 hover:bg-zinc-700"
                ]}
              >
                processed
              </button>
              <button
                phx-click="set_filter"
                phx-value-filter="slipbox"
                class={[
                  "px-2 py-1 rounded transition-colors",
                  @filter == :slipbox && "bg-amber-600 text-white",
                  @filter != :slipbox && "bg-zinc-800 text-zinc-400 hover:bg-zinc-700"
                ]}
              >
                slipbox
              </button>
            </div>

            <%!-- Stats --%>
            <div class="text-zinc-500 text-xs">
              <%= length(@graph_data.nodes) %> nodes, <%= length(@graph_data.edges) %> links
            </div>
          </div>
        </header>

        <%!-- Main content: Graph + Side Panel --%>
        <div class="flex-1 flex overflow-hidden">
          <%!-- Graph container --%>
          <%= if @graph_data.nodes == [] do %>
            <div class="flex-1 flex items-center justify-center text-zinc-500">
              <div class="text-center">
                <div class="text-6xl mb-4 opacity-50">&#x25CE;</div>
                <p class="text-lg">No nodes in zettelkasten yet</p>
                <p class="text-sm mt-2">The retrospector will populate it over time.</p>
              </div>
            </div>
          <% else %>
            <div
              id="cytoscape-graph"
              phx-hook="CytoscapeGraph"
              phx-update="ignore"
              data-graph={Jason.encode!(@graph_data)}
              data-soul-id={@soul_id}
              class="flex-1 bg-zinc-950"
            >
            </div>
          <% end %>

          <%!-- Side Panel --%>
          <%= if @selected_node do %>
            <aside class="w-96 border-l border-zinc-700 bg-zinc-900 overflow-y-auto">
              <div class="p-4">
                <%!-- Header --%>
                <div class="flex items-start justify-between mb-4">
                  <div class="flex items-center gap-2">
                    <div class={[
                      "w-3 h-3 rounded-full",
                      @selected_node.processed && "bg-teal-400",
                      !@selected_node.processed && "bg-amber-400"
                    ]}></div>
                    <span class="text-xs text-zinc-500">
                      <%= if @selected_node.processed, do: "processed", else: "slipbox" %>
                    </span>
                  </div>
                  <button
                    phx-click="node_deselected"
                    class="text-zinc-500 hover:text-zinc-300 text-xl leading-none"
                  >
                    &times;
                  </button>
                </div>

                <%!-- ID --%>
                <div class="mb-4">
                  <label class="block text-xs text-zinc-500 mb-1">ID</label>
                  <code class="text-xs text-zinc-400 break-all"><%= @selected_node.id %></code>
                </div>

                <%!-- Content --%>
                <div class="mb-4">
                  <label class="block text-xs text-zinc-500 mb-1">Content</label>
                  <div class="text-sm text-zinc-200 whitespace-pre-wrap break-words bg-zinc-800 rounded p-3 max-h-64 overflow-y-auto">
                    <%= @selected_node.content %>
                  </div>
                </div>

                <%!-- Metadata --%>
                <div class="grid grid-cols-2 gap-4 mb-4">
                  <div>
                    <label class="block text-xs text-zinc-500 mb-1">Links</label>
                    <span class="text-sm text-zinc-200"><%= @selected_node.link_count %></span>
                  </div>
                  <div>
                    <label class="block text-xs text-zinc-500 mb-1">Created</label>
                    <span class="text-sm text-zinc-200"><%= format_date(@selected_node.inserted_at) %></span>
                  </div>
                </div>

                <%!-- Linked Nodes --%>
                <%= if @selected_node.links != [] do %>
                  <div>
                    <label class="block text-xs text-zinc-500 mb-2">Linked Nodes</label>
                    <div class="space-y-2">
                      <%= for link <- @selected_node.links do %>
                        <button
                          phx-click="select_linked_node"
                          phx-value-id={link.id}
                          class="w-full text-left p-2 bg-zinc-800 hover:bg-zinc-700 rounded text-xs text-zinc-400 truncate transition-colors"
                        >
                          <%= link.preview %>...
                        </button>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            </aside>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_date(nil), do: "-"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end
