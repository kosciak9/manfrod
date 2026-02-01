defmodule ManfrodWeb.Router do
  use ManfrodWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {ManfrodWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check endpoint - no auth required
  scope "/api", ManfrodWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  scope "/", ManfrodWeb do
    pipe_through :browser

    live "/", ChatLive
  end

  # LiveDashboard for debugging
  import Phoenix.LiveDashboard.Router

  scope "/dev" do
    pipe_through [:fetch_session, :protect_from_forgery]

    live_dashboard "/dashboard"
  end
end
