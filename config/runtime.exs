import Config
import Dotenvy

# Load .env file, system env takes precedence
source!([".env", System.get_env()])

# Database - default to local podman compose instance
database_url =
  env!("DATABASE_URL", :string, "ecto://manfred:qLmVMeXiYyy65ADb@localhost:35232/manfred")

config :manfred, Manfred.Repo,
  url: database_url,
  pool_size: env!("POOL_SIZE", :integer, 10)

# Endpoint
secret_key_base =
  env!(
    "SECRET_KEY_BASE",
    :string,
    "u4j9UKEyW8U1/ddckTtl9Va+v4X4eXQp4xu+0xnGerLY8elQoJVK5f+gKIfVvslH"
  )

config :manfred, ManfredWeb.Endpoint,
  http: [
    ip: {0, 0, 0, 0},
    port: env!("PORT", :integer, 35233)
  ],
  secret_key_base: secret_key_base,
  server: true

# Zen API (Kimi K2.5)
config :manfred, :zen_api_key, env!("ZEN_API_KEY", :string?)
