defmodule ManfrodWeb.SetupLive do
  @moduledoc """
  Setup wizard for configuring credentials on first run.

  Presents a form with masked inputs for GitHub token and Gmail
  credentials. Credentials are stored encrypted in the database.
  """
  use ManfrodWeb, :live_view

  alias Manfrod.Credentials
  alias Manfrod.Credentials.Credential

  @impl true
  def mount(_params, _session, socket) do
    existing = Credentials.get()

    changeset =
      if existing do
        Credential.changeset(existing, %{})
      else
        Credential.changeset(%Credential{}, %{})
      end

    socket =
      socket
      |> assign(:page_title, "Setup")
      |> assign(:existing, existing)
      |> assign(:saved, false)
      |> assign_form(changeset)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-lg mx-auto px-4 py-12 font-mono">
        <h1 class="text-2xl text-zinc-100 mb-2">setup</h1>
        <p class="text-zinc-500 text-sm mb-8">
          Configure credentials for GitHub and Gmail integration.
          All values are stored encrypted in the database.
        </p>

        <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-6">
          <div>
            <label for="credential_github_token" class="block text-sm text-zinc-400 mb-1">
              GitHub Personal Access Token
            </label>
            <input
              type="password"
              name={@form[:github_token].name}
              id="credential_github_token"
              value={@form[:github_token].value}
              placeholder={if @existing, do: "••••••••  (saved)", else: "ghp_..."}
              autocomplete="off"
              class="w-full bg-zinc-800 border border-zinc-700 rounded px-3 py-2 text-zinc-200 text-sm font-mono placeholder-zinc-600 focus:outline-none focus:border-blue-500"
            />
            <p :if={@form[:github_token].errors != []} class="text-red-400 text-xs mt-1">
              {error_message(@form[:github_token].errors)}
            </p>
          </div>

          <div>
            <label for="credential_gmail_email" class="block text-sm text-zinc-400 mb-1">
              Gmail Address
            </label>
            <input
              type="email"
              name={@form[:gmail_email].name}
              id="credential_gmail_email"
              value={@form[:gmail_email].value}
              placeholder={if @existing, do: "••••••••  (saved)", else: "user@gmail.com"}
              autocomplete="off"
              class="w-full bg-zinc-800 border border-zinc-700 rounded px-3 py-2 text-zinc-200 text-sm font-mono placeholder-zinc-600 focus:outline-none focus:border-blue-500"
            />
            <p :if={@form[:gmail_email].errors != []} class="text-red-400 text-xs mt-1">
              {error_message(@form[:gmail_email].errors)}
            </p>
          </div>

          <div>
            <label for="credential_gmail_app_password" class="block text-sm text-zinc-400 mb-1">
              Gmail App Password
            </label>
            <input
              type="password"
              name={@form[:gmail_app_password].name}
              id="credential_gmail_app_password"
              value={@form[:gmail_app_password].value}
              placeholder={if @existing, do: "••••••••  (saved)", else: "xxxx xxxx xxxx xxxx"}
              autocomplete="off"
              class="w-full bg-zinc-800 border border-zinc-700 rounded px-3 py-2 text-zinc-200 text-sm font-mono placeholder-zinc-600 focus:outline-none focus:border-blue-500"
            />
            <p :if={@form[:gmail_app_password].errors != []} class="text-red-400 text-xs mt-1">
              {error_message(@form[:gmail_app_password].errors)}
            </p>
          </div>

          <div class="flex items-center gap-4">
            <button
              type="submit"
              class="bg-blue-600 hover:bg-blue-500 text-white px-4 py-2 rounded text-sm font-mono transition-colors"
            >
              {if @existing, do: "update credentials", else: "save credentials"}
            </button>

            <span :if={@saved} class="text-green-400 text-sm">
              saved successfully
            </span>
          </div>
        </.form>

        <div :if={@existing} class="mt-8 pt-6 border-t border-zinc-800">
          <p class="text-zinc-500 text-xs">
            Credentials were last updated {format_time(@existing.updated_at)}.
            Submitting empty fields will keep existing values.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"credential" => params}, socket) do
    changeset =
      (socket.assigns.existing || %Credential{})
      |> Credential.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"credential" => params}, socket) do
    # Filter out empty values when updating (keep existing)
    params =
      if socket.assigns.existing do
        params
        |> Enum.reject(fn {_k, v} -> v == "" end)
        |> Map.new()
      else
        params
      end

    case Credentials.save(params) do
      {:ok, credential} ->
        socket =
          socket
          |> assign(:existing, credential)
          |> assign(:saved, true)
          |> assign_form(Credential.changeset(credential, %{}))
          |> put_flash(:info, "Credentials saved successfully.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: "credential"))
  end

  defp error_message([{msg, _opts} | _]), do: msg
  defp error_message(_), do: nil

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end
