defmodule Manfred.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Manfred.Repo,
        {Phoenix.PubSub, name: Manfred.PubSub},
        Manfred.Agent,
        ManfredWeb.Endpoint
      ] ++ telegram_children()

    opts = [strategy: :one_for_one, name: Manfred.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp telegram_children do
    case Application.get_env(:manfred, :telegram_bot_token) do
      nil ->
        []

      token ->
        [
          ExGram,
          {Manfred.Telegram.Bot, [method: :polling, token: token]}
        ]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ManfredWeb.Endpoint.config_change(changed, removed)

    :ok
  end
end
