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

  # Health check - accessible during setup, no auth
  scope "/", ManfrodWeb do
    pipe_through :api

    get "/health", HealthController, :index
    # Keep old path for backward compatibility
    get "/api/health", HealthController, :index
  end

  # Setup wizard - always accessible (no setup redirect)
  scope "/", ManfrodWeb do
    pipe_through :browser

    live "/setup", SetupLive
  end

  # Main app routes - redirect to /setup if credentials missing
  scope "/", ManfrodWeb do
    pipe_through [:browser, ManfrodWeb.Plugs.RequireSetup]

    live "/", ActivityLive
    live "/chat", ChatLive
    live "/dashboard", DashboardLive
    live "/graph", GraphLive
    live "/self-improvement", SelfImprovementLive
  end

  # LiveDashboard for debugging
  import Phoenix.LiveDashboard.Router

  scope "/dev" do
    pipe_through [:fetch_session, :protect_from_forgery]

    live_dashboard "/dashboard"
  end
end
