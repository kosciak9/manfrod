defmodule ManfredWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :manfred

  @session_options [
    store: :cookie,
    key: "_manfred_key",
    signing_salt: "tCnVqZxQ",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :manfred,
    gzip: false,
    only: ManfredWeb.static_paths()

  # Serve Phoenix and LiveView JS from deps
  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false

  plug Plug.Static,
    at: "/assets/lv",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :manfred
  end

  if Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ManfredWeb.Router
end
