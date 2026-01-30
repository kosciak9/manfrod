import Config

config :manfred,
  ecto_repos: [Manfred.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :manfred, ManfredWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Manfred.PubSub,
  live_view: [signing_salt: "5e3ieG0i"],
  code_reloader: true

config :logger, :default_formatter,
  format: "[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
