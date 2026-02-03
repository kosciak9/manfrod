defmodule ManfrodWeb.Layouts do
  @moduledoc """
  Layout components for the application.
  """
  use Phoenix.Component

  @doc """
  The root layout - outermost HTML wrapper.
  """
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Manfrod</title>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link href="https://fonts.googleapis.com/css2?family=Overpass+Mono:wght@400;600&display=swap" rel="stylesheet" />
        <link phx-track-static rel="stylesheet" href="/assets/app.css" />
        <script src="/assets/phoenix/phoenix.min.js">
        </script>
        <script src="/assets/lv/phoenix_live_view.min.js">
        </script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            params: { _csrf_token: csrfToken }
          });
          liveSocket.connect();
        </script>
      </head>
      <body class="bg-zinc-900 text-zinc-200 antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc """
  The app layout - wraps page content.
  """
  attr :flash, :map, default: %{}
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main class={@class}>
      {render_slot(@inner_block)}
    </main>
    """
  end

  @doc """
  Navigation bar component.
  """
  attr :current, :atom, required: true

  def nav(assigns) do
    ~H"""
    <nav class="flex items-center gap-4">
      <.nav_link href="/" label="activity" current={@current == :activity} />
      <.nav_link href="/dashboard" label="dashboard" current={@current == :dashboard} />
    </nav>
    """
  end

  defp nav_link(assigns) do
    ~H"""
    <%= if @current do %>
      <span class="text-blue-400 font-semibold text-base tracking-wide"><%= @label %></span>
    <% else %>
      <a href={@href} class="text-zinc-500 hover:text-zinc-300 text-sm transition-colors"><%= @label %></a>
    <% end %>
    """
  end
end
