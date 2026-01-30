defmodule Manfred.Repo do
  use Ecto.Repo,
    otp_app: :manfred,
    adapter: Ecto.Adapters.Postgres
end
