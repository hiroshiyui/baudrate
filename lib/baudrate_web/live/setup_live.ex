defmodule BaudrateWeb.SetupLive do
  @moduledoc """
  LiveView for the first-time setup wizard.

  Guides the user through a multi-step process using `@step` assigns:

    0. `:verify_key` — (optional) validates the `INSTALLATION_KEY` env var
    1. `:database` — verifies PostgreSQL connection and migration status
    2. `:site_name` — collects the forum name (stored as a `Setting`)
    3. `:admin_account` — creates the initial admin user with password validation
    4. `:recovery_codes` — displays recovery codes for the admin to save

  When the `INSTALLATION_KEY` environment variable is configured (production),
  the wizard starts at `:verify_key` to gate access. The key is validated with
  constant-time comparison (`Plug.Crypto.secure_compare/2`). After 3 failed
  attempts, the form is locked for 30 seconds to prevent brute-force.

  The key gate is enforced on the **event handler**, not merely on the rendered
  step: a client speaking the LiveView protocol directly can push any
  `handle_event/3` message regardless of which step is displayed, so
  `"complete_setup"` refuses to run unless `@key_verified` is true. Without that
  check the `INSTALLATION_KEY` could be skipped entirely and any visitor to a
  freshly deployed instance could claim the admin account.

  On completion, `Setup.complete_setup/2` runs all steps in a single transaction.
  Uses `layout: :setup` (minimal layout without navigation bar).
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Setup
  alias Baudrate.Setup.InstallationKey
  import BaudrateWeb.Helpers, only: [password_strength: 1]

  @lockout_duration_seconds 30
  @max_key_attempts 3

  @impl true
  def mount(params, session, socket) do
    # The plug pipeline does not run for the LiveView websocket, so the setup
    # lock has to be re-checked here as well as in `EnsureSetup`.
    if InstallationKey.status() == {:error, :missing} do
      {:ok,
       socket
       |> put_flash(:error, gettext("Setup is locked. Contact the server operator."))
       |> redirect(to: "/")}
    else
      do_mount(params, session, socket)
    end
  end

  defp do_mount(_params, _session, socket) do
    {db_status, migrations_status} = check_system()

    site_name_changeset = Setup.change_site_name(%{site_name: "Baudrate"})
    admin_changeset = Setup.change_user_registration()

    key_required = not is_nil(InstallationKey.configured_key())

    initial_step = if key_required, do: :verify_key, else: :database

    socket =
      socket
      |> assign(:step, initial_step)
      |> assign(:key_required, key_required)
      |> assign(:key_verified, not key_required)
      |> assign(:key_error, nil)
      |> assign(:key_attempts, 0)
      |> assign(:key_locked_until, nil)
      |> assign(:db_status, db_status)
      |> assign(:migrations_status, migrations_status)
      |> assign(:site_name, "Baudrate")
      |> assign(:site_name_form, to_form(site_name_changeset, as: :site))
      |> assign(:admin_form, to_form(admin_changeset, as: :admin))
      |> assign(:password_strength, password_strength(""))
      |> assign(:recovery_codes, nil)
      |> assign(:page_title, gettext("Setup"))

    {:ok, socket, layout: {BaudrateWeb.Layouts, :setup}}
  end

  @impl true
  def handle_event("verify_key", %{"key" => %{"installation_key" => submitted_key}}, socket) do
    if key_locked?(socket) do
      {:noreply,
       assign(socket, :key_error, gettext("Too many attempts. Please wait before trying again."))}
    else
      if InstallationKey.verify(submitted_key) do
        {:noreply,
         socket
         |> go_to_step(:database)
         |> assign(:key_verified, true)
         |> assign(:key_error, nil)}
      else
        attempts = socket.assigns.key_attempts + 1

        locked_until =
          if attempts >= @max_key_attempts do
            System.monotonic_time(:second) + @lockout_duration_seconds
          else
            socket.assigns.key_locked_until
          end

        {:noreply,
         socket
         |> assign(:key_error, gettext("Invalid installation key."))
         |> assign(:key_attempts, attempts)
         |> assign(:key_locked_until, locked_until)}
      end
    end
  end

  # A raw LiveView client can push a malformed payload; without this clause it
  # crashes the wizard process with a FunctionClauseError.
  def handle_event("verify_key", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("check_database", _params, socket) do
    {db_status, migrations_status} = check_system()

    {:noreply,
     socket
     |> assign(:db_status, db_status)
     |> assign(:migrations_status, migrations_status)}
  end

  @impl true
  def handle_event("next_from_database", _params, socket) do
    {:noreply, go_to_step(socket, :site_name)}
  end

  @impl true
  def handle_event("validate_site_name", %{"site" => params}, socket) do
    changeset =
      Setup.change_site_name(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :site_name_form, to_form(changeset, as: :site))}
  end

  @impl true
  def handle_event("save_site_name", %{"site" => %{"site_name" => site_name}}, socket) do
    changeset = Setup.change_site_name(%{site_name: site_name})

    if changeset.valid? do
      {:noreply,
       socket
       |> assign(:site_name, site_name)
       |> go_to_step(:admin_account)}
    else
      changeset = Map.put(changeset, :action, :validate)
      {:noreply, assign(socket, :site_name_form, to_form(changeset, as: :site))}
    end
  end

  @impl true
  def handle_event("validate_admin", %{"admin" => params}, socket) do
    changeset =
      Setup.change_user_registration(%Baudrate.Setup.User{}, params)
      |> Map.put(:action, :validate)

    password = params["password"] || ""

    {:noreply,
     socket
     |> assign(:admin_form, to_form(changeset, as: :admin))
     |> assign(:password_strength, password_strength(password))}
  end

  @impl true
  def handle_event("complete_setup", _params, %{assigns: %{key_verified: false}} = socket) do
    # A LiveView client can push any event regardless of the rendered step, so
    # the installation-key gate must be re-checked here and not only in the UI.
    {:noreply,
     socket
     |> go_to_step(:verify_key)
     |> assign(:key_error, gettext("Invalid installation key."))}
  end

  def handle_event("complete_setup", %{"admin" => params}, socket) do
    case Setup.complete_setup(socket.assigns.site_name, params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:recovery_codes, result.recovery_codes)
         |> go_to_step(:recovery_codes)}

      {:error, :admin_user, changeset, _changes} ->
        {:noreply, assign(socket, :admin_form, to_form(changeset, as: :admin))}

      {:error, _failed_op, _changeset, _changes} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Setup failed. Please try again."))}
    end
  end

  @impl true
  def handle_event("ack_codes", _params, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Setup completed successfully!"))
     |> redirect(to: "/")}
  end

  @impl true
  def handle_event("back_to_database", _params, socket) do
    {:noreply, go_to_step(socket, :database)}
  end

  @impl true
  def handle_event("back_to_site_name", _params, socket) do
    {:noreply, go_to_step(socket, :site_name)}
  end

  # Each step swaps the whole step container, which drops keyboard focus to
  # <body>. Moving focus to the new step's heading (handled by the global
  # "focus" event listener in app.js) keeps screen-reader and keyboard users
  # oriented in the wizard.
  @step_heading_ids %{
    verify_key: "setup-verify-key-title",
    database: "setup-database-connection-title",
    site_name: "setup-site-name-title",
    admin_account: "setup-admin-account-title",
    recovery_codes: "setup-recovery-codes-title"
  }

  defp go_to_step(socket, step) do
    socket
    |> assign(:step, step)
    |> push_event("focus", %{id: Map.fetch!(@step_heading_ids, step)})
  end

  defp key_locked?(socket) do
    case socket.assigns.key_locked_until do
      nil -> false
      locked_until -> System.monotonic_time(:second) < locked_until
    end
  end

  defp check_system do
    db_status = Setup.check_database()
    migrations_status = Setup.check_migrations()
    {db_status, migrations_status}
  end
end
