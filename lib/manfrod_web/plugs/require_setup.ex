defmodule ManfrodWeb.Plugs.RequireSetup do
  @moduledoc """
  Redirects to /setup when credentials have not been configured.

  Skips the check for:
  - /setup itself
  - /health (health check endpoint)
  - /dev/* (LiveDashboard)
  - /api/* (API endpoints)
  - Static assets
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(%{request_path: "/setup"} = conn, _opts), do: conn
  def call(%{request_path: "/health"} = conn, _opts), do: conn
  def call(%{request_path: "/dev/" <> _} = conn, _opts), do: conn
  def call(%{request_path: "/api/" <> _} = conn, _opts), do: conn
  def call(%{request_path: "/assets/" <> _} = conn, _opts), do: conn
  def call(%{request_path: "/live/" <> _} = conn, _opts), do: conn

  def call(conn, _opts) do
    if Manfrod.Credentials.configured?() do
      conn
    else
      conn
      |> redirect(to: "/setup")
      |> halt()
    end
  end
end
