defmodule ManfrodWeb.ErrorHTML do
  @moduledoc """
  Error pages for HTML requests.
  """

  use Phoenix.Component

  def render("404.html", _assigns) do
    error_page(404, "Not Found", "#7E9CD8")
  end

  def render("500.html", _assigns) do
    error_page(500, "Internal Server Error", "#E82424")
  end

  def render(template, _assigns) do
    status =
      template
      |> String.replace(".html", "")
      |> String.to_integer()

    error_page(status, "Error", "#FF9E3B")
  end

  defp error_page(status, message, color) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{message}</title>
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, sans-serif;
            background: #1F1F28;
            color: #DCD7BA;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
          }
          .container {
            text-align: center;
          }
          h1 {
            font-size: 4rem;
            color: #{color};
            margin: 0;
          }
          p {
            color: #727169;
            margin-top: 1rem;
          }
          a {
            color: #7FB4CA;
            text-decoration: none;
          }
          a:hover {
            text-decoration: underline;
          }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>#{status}</h1>
          <p>#{message}</p>
          <p><a href="/">Back to activity</a></p>
        </div>
      </body>
    </html>
    """
    |> Phoenix.HTML.raw()
  end
end
