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
        <style>
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body { font-family: system-ui, sans-serif; background: #1a1a1a; color: #e0e0e0; }
        </style>
        <script src="/assets/phoenix/phoenix.min.js"></script>
        <script src="/assets/lv/phoenix_live_view.min.js"></script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            params: { _csrf_token: csrfToken }
          });
          liveSocket.connect();
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc """
  The app layout - wraps page content.
  """
  attr :flash, :map, default: %{}
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main style="max-width: 800px; margin: 0 auto; padding: 20px;">
      {render_slot(@inner_block)}
    </main>
    """
  end
end
