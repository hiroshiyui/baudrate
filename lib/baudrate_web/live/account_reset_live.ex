defmodule BaudrateWeb.AccountResetLive do
  @moduledoc """
  Redeems an admin-issued reset link at `/account-reset/:token`
  ([ADR 0058](../../../doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md)).

  The person arriving here has lost their password and their recovery codes.
  They proved who they were out of band — a signed message from an address
  registered on the account, verified by an admin in their own mail client —
  and were handed this link through that same channel. This instance sends no
  mail and checked no signature.

  **Every failure looks the same.** An unknown token, an expired one, one
  already spent and one revoked all render the same refusal, so the page is
  not an oracle for whether a given link ever existed. The token is only
  checked when the form is submitted, for the same reason: mounting the page
  must not tell a scanner anything.

  Succeeding takes the account back from whoever else may have it: every
  session is revoked, exports and moves are cancelled, and a fresh set of
  recovery codes is issued and shown once. Second factors survive unless the
  issuing admin ticked that box.
  """

  use BaudrateWeb, :live_view

  require Logger

  alias Baudrate.Auth
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.Helpers, only: [password_strength: 1, extract_peer_ip: 1]

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     socket
     |> assign(:token, token)
     |> assign(:form, to_form(%{"password" => "", "password_confirmation" => ""}, as: :reset))
     |> assign(:password_strength, password_strength(""))
     |> assign(:codes, nil)
     |> assign(:peer_ip, if(connected?(socket), do: extract_peer_ip(socket), else: "unknown"))
     |> assign(:page_title, gettext("Account Recovery"))}
  end

  @impl true
  def handle_event("validate", %{"reset" => params}, socket) do
    {:noreply,
     socket
     |> assign(:form, to_form(params, as: :reset))
     |> assign(:password_strength, password_strength(params["password"] || ""))}
  end

  @impl true
  def handle_event("submit", %{"reset" => params}, socket) do
    ip = socket.assigns.peer_ip

    case RateLimits.check_account_reset_by_ip(ip) do
      {:error, :rate_limited} ->
        Logger.warning("rate_limit.denied: action=account_reset ip=#{ip}")

        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

      :ok ->
        redeem(socket, params)
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp redeem(socket, params) do
    case Auth.redeem_account_reset(
           socket.assigns.token,
           params["password"] || "",
           params["password_confirmation"] || ""
         ) do
      {:ok, user, codes} ->
        Logger.info(
          "auth.account_reset_redeemed: user_id=#{user.id} ip=#{socket.assigns.peer_ip}"
        )

        {:noreply,
         socket
         |> assign(:codes, codes)
         |> put_flash(:info, gettext("Your password has been set. Save these recovery codes."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        # The link was spent claiming this attempt — replaying it would turn a
        # single-use token into a password-guessing loop. Say so, because
        # otherwise a mistyped confirmation looks like a broken link.
        {:noreply,
         socket
         |> assign(:form, to_form(changeset, as: :reset))
         |> put_flash(
           :error,
           gettext(
             "That password was not accepted, and this link is now spent. Ask for a new one."
           )
         )}

      {:error, :invalid} ->
        Logger.warning("auth.account_reset_invalid: ip=#{socket.assigns.peer_ip}")

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This link is not valid. It may have expired or already been used.")
         )}
    end
  end
end
