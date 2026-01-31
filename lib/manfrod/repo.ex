defmodule Manfrod.Repo do
  use Ecto.Repo,
    otp_app: :manfrod,
    adapter: Ecto.Adapters.Postgres
end
