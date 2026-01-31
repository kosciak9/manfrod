defmodule Manfrod.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Manfrod.Repo,
        {Phoenix.PubSub, name: Manfrod.PubSub},
        Manfrod.Agent,
        ManfrodWeb.Endpoint
      ] ++ telegram_children()

    opts = [strategy: :one_for_one, name: Manfrod.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp telegram_children do
    case Application.get_env(:manfrod, :telegram_bot_token) do
      nil ->
        []

      token ->
        [
          ExGram,
          {Manfrod.Telegram.Bot, [method: :polling, token: token]}
        ]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ManfrodWeb.Endpoint.config_change(changed, removed)

    :ok
  end
end
