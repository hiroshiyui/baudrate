defmodule BaudrateWeb.PasswordResetLive do
  @moduledoc """
  LiveView for password reset using a recovery code.

  Users enter their username, a single-use recovery code, and a new password.
  Rate limited to 5 attempts per hour per IP to prevent brute-force attacks.
  Lives in the `:public` live_session with `redirect_if_authenticated`.
  """

  use BaudrateWeb, :live_view

  require Logger

  alias Baudrate.Auth

  @impl true
  def mount(_params, _session, socket) do
    peer_ip =
      if connected?(socket) do
        case get_connect_info(socket, :peer_data) do
          %{address: addr} -> addr |> :inet.ntoa() |> to_string()
          _ -> "unknown"
        end
      else
        "unknown"
      end

    socket =
      socket
      |> assign(:form, to_form(%{}, as: :reset))
      |> assign(:password_strength, password_strength(""))
      |> assign(:peer_ip, peer_ip)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"reset" => params}, socket) do
    password = params["new_password"] || ""
    {:noreply, assign(socket, :password_strength, password_strength(password))}
  end

  @impl true
  def handle_event("submit", %{"reset" => params}, socket) do
    ip = socket.assigns.peer_ip

    case Hammer.check_rate("password_reset:#{ip}", 3_600_000, 5) do
      {:deny, _limit} ->
        Logger.warning("rate_limit.denied: action=password_reset ip=#{ip}")

        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

      _ ->
        do_reset(socket, params)
    end
  end

  defp do_reset(socket, params) do
    username = params["username"] || ""
    recovery_code = params["recovery_code"] || ""
    new_password = params["new_password"] || ""
    new_password_confirmation = params["new_password_confirmation"] || ""

    case Auth.reset_password_with_recovery_code(
           username,
           recovery_code,
           new_password,
           new_password_confirmation
         ) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Password reset successful! You can now sign in."))
         |> redirect(to: ~p"/login")}

      {:error, :invalid_credentials} ->
        {:noreply,
         put_flash(socket, :error, gettext("Invalid username or recovery code."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)

        password_errors = Map.get(errors, :password, [])
        error_msg = Enum.join(password_errors, ", ")

        {:noreply,
         put_flash(
           socket,
           :error,
           if(error_msg != "", do: error_msg, else: gettext("Password reset failed."))
         )}
    end
  end

  defp password_strength(password) do
    %{
      length: String.length(password) >= 12,
      lowercase: Regex.match?(~r/[a-z]/, password),
      uppercase: Regex.match?(~r/[A-Z]/, password),
      digit: Regex.match?(~r/[0-9]/, password),
      special: Regex.match?(~r/[^a-zA-Z0-9]/, password)
    }
  end
end
