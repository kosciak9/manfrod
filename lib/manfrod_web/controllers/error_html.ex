defmodule ManfrodWeb.ErrorHTML do
  @moduledoc """
  Error pages for HTML requests.
  """

  use Phoenix.Component

  def render("404.html", _assigns) do
    error_page(404, "Not Found", "#7E9CD8", nil)
  end

  def render("500.html", assigns) do
    error_details = format_error(assigns[:reason])
    error_page(500, "Internal Server Error", "#E82424", error_details)
  end

  def render(template, _assigns) do
    status =
      template
      |> String.replace(".html", "")
      |> String.to_integer()

    error_page(status, "Error", "#FF9E3B", nil)
  end

  defp format_error(nil), do: nil

  defp format_error(reason) do
    reason
    |> Exception.message()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp error_page(status, message, color, error_details) do
    details_html =
      if error_details do
        """
        <pre class="error-details">#{error_details}</pre>
        """
      else
        ""
      end

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
            max-width: 800px;
            padding: 2rem;
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
          .error-details {
            background: #2A2A37;
            color: #E82424;
            padding: 1rem;
            border-radius: 0.5rem;
            text-align: left;
            overflow-x: auto;
            font-family: "SF Mono", "Fira Code", "Consolas", monospace;
            font-size: 0.875rem;
            margin-top: 1.5rem;
            white-space: pre-wrap;
            word-break: break-word;
          }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>#{status}</h1>
          <p>#{message}</p>
          #{details_html}
          <p><a href="/">Back to activity</a></p>
        </div>
      </body>
    </html>
    """
    |> Phoenix.HTML.raw()
  end
end
