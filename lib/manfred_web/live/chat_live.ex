defmodule ManfredWeb.ChatLive do
  @moduledoc """
  Chat interface for talking to Manfred.Agent.
  """
  use ManfredWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       messages: [],
       input: ""
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div style="display: flex; flex-direction: column; height: 90vh;">
        <h1 style="margin-bottom: 20px;">Manfred</h1>

        <div style="flex: 1; overflow-y: auto; border: 1px solid #333; padding: 10px; margin-bottom: 10px; border-radius: 4px;">
          <%= for {role, text} <- @messages do %>
            <div style={"margin-bottom: 10px; padding: 8px; border-radius: 4px; #{if role == :user, do: "background: #2a2a4a; text-align: right;", else: "background: #2a4a2a;"}"}>
              <strong><%= if role == :user, do: "You", else: "Manfred" %></strong>
              <p style="margin-top: 4px; white-space: pre-wrap;"><%= text %></p>
            </div>
          <% end %>
        </div>

        <form phx-submit="send" style="display: flex; gap: 10px;">
          <input
            type="text"
            name="message"
            value={@input}
            placeholder="Type a message..."
            autocomplete="off"
            style="flex: 1; padding: 10px; border: 1px solid #333; border-radius: 4px; background: #2a2a2a; color: #e0e0e0;"
          />
          <button type="submit" style="padding: 10px 20px; background: #4a4a8a; border: none; border-radius: 4px; color: white; cursor: pointer;">
            Send
          </button>
        </form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("send", %{"message" => ""}, socket) do
    {:noreply, socket}
  end

  def handle_event("send", %{"message" => message}, socket) do
    # Add user message
    messages = socket.assigns.messages ++ [{:user, message}]

    # Get response from agent
    {:response, response} = Manfred.Agent.message(message)

    # Add agent response
    messages = messages ++ [{:agent, response}]

    {:noreply, assign(socket, messages: messages, input: "")}
  end
end
