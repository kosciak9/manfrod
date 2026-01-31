defmodule ManfrodWeb.ChatLive do
  @moduledoc """
  Placeholder for future configuration UI.
  Chat functionality has moved to Telegram.
  """
  use ManfrodWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 80vh;">
        <h1 style="margin-bottom: 20px;">Manfrod</h1>
        <p style="color: #888; margin-bottom: 10px;">
          Chat with Manfrod via Telegram.
        </p>
        <p style="color: #666; font-size: 0.9em;">
          Configuration UI coming soon.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
