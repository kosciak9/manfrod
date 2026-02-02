defmodule Manfrod.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Manfrod.Repo,
        {Phoenix.PubSub, name: Manfrod.PubSub},
        {Oban, Application.fetch_env!(:manfrod, Oban)},
        # Event handlers (subscribe to PubSub)
        Manfrod.Events.Persister,
        Manfrod.Memory.FlushHandler,
        Manfrod.Telegram.ActivityHandler,
        # Core agent
        Manfrod.Agent,
        ManfrodWeb.Endpoint
      ] ++ telegram_children()

    opts = [strategy: :one_for_one, name: Manfrod.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Add logger handler after PubSub is running
    add_log_handler()

    result
  end

  defp add_log_handler do
    handler_config = %{
      level: :all
    }

    :logger.add_handler(:manfrod_log_handler, Manfrod.Events.LogHandler, handler_config)
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
