import Config

config :manfrod,
  ecto_repos: [Manfrod.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :manfrod, Manfrod.Repo, types: Manfrod.PostgrexTypes

config :manfrod, ManfrodWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Manfrod.PubSub,
  live_view: [signing_salt: "5e3ieG0i"],
  code_reloader: true

config :logger, :default_formatter,
  format: "[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# ExGram (Telegram bot)
config :ex_gram, adapter: ExGram.Adapter.Req
