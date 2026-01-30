defmodule Manfred.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Manfred.Repo,
      {Phoenix.PubSub, name: Manfred.PubSub},
      Manfred.Agent,
      ManfredWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Manfred.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ManfredWeb.Endpoint.config_change(changed, removed)

    :ok
  end
end
