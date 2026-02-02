defmodule ManfrodWeb.ErrorJSON do
  @moduledoc """
  Error responses for JSON API requests.
  """

  def render("404.json", _assigns) do
    %{error: "Not found"}
  end

  def render("500.json", _assigns) do
    %{error: "Internal server error"}
  end

  def render(template, _assigns) do
    status = template |> String.replace(".json", "") |> String.to_integer()
    %{error: "Error #{status}"}
  end
end
