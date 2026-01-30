defmodule ManfredWeb.Router do
  use ManfredWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {ManfredWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", ManfredWeb do
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
