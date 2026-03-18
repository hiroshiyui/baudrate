defmodule BaudrateWeb.Admin.BotsLive do
  @moduledoc """
  LiveView for admin bot management.

  Only accessible to users with the `"admin"` role. Provides CRUD
  operations for RSS/Atom feed bot accounts: create, edit, delete,
  and toggle active state.

  ## Bot Profile Editing

  Both the create and edit forms include a `bio` field. On creation,
  the bio defaults to the feed URL when left blank. On edit, the
  current bio is pre-filled and always submitted explicitly — the
  auto-bio-from-feed_url fallback only fires when no explicit bio is
  provided (i.e. from non-UI callers).

  The edit form also exposes 4 profile field rows (name + value) that
  are published as `PropertyValue` attachments on the AP actor,
  following the Mastodon convention. Admins can use these to add
  disclaimers such as "Unofficial — not affiliated with the source."
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Bots
  alias Baudrate.Bots.Bot
  alias Baudrate.Bots.FaviconFetcher
  alias Baudrate.Content
  alias Baudrate.Moderation
  import BaudrateWeb.Helpers, only: [parse_id: 1]

  @impl true
  def mount(_params, _session, socket) do
    bots = Bots.list_bots()
    boards = Content.list_all_boards()

    {:ok,
     assign(socket,
       bots: bots,
       boards: boards,
       editing_bot: nil,
       editing_bot_profile_fields: [],
       form: nil,
       show_form: false,
       wide_layout: true,
       page_title: gettext("Manage Bots")
     )}
  end

  @impl true
  def handle_event("new", _params, socket) do
    changeset = Bot.create_changeset(%Bot{}, %{})

    {:noreply,
     assign(socket, show_form: true, editing_bot: nil, form: to_form(changeset, as: :bot))}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, bot_id} ->
        bot = Bots.get_bot!(bot_id)
        changeset = Bot.update_changeset(bot, %{})

        {:noreply,
         assign(socket,
           show_form: true,
           editing_bot: bot,
           editing_bot_profile_fields: pad_profile_fields(bot.user.profile_fields),
           form: to_form(changeset, as: :bot)
         )}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply,
     assign(socket, show_form: false, editing_bot: nil, editing_bot_profile_fields: [], form: nil)}
  end

  @impl true
  def handle_event("validate", %{"bot" => params}, socket) do
    changeset =
      if socket.assigns.editing_bot do
        Bot.update_changeset(socket.assigns.editing_bot, params)
      else
        Bot.create_changeset(%Bot{}, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :bot))}
  end

  @impl true
  def handle_event("save", %{"bot" => params}, socket) do
    if socket.assigns.editing_bot do
      save_edit(socket, params)
    else
      save_new(socket, params)
    end
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, bot_id} ->
        bot = Bots.get_bot!(bot_id)
        new_active = not bot.active

        case Bots.update_bot(bot, %{active: new_active}) do
          {:ok, _updated} ->
            Moderation.log_action(socket.assigns.current_user.id, "toggle_bot",
              target_type: "bot",
              target_id: bot_id,
              details: %{"active" => new_active}
            )

            flash_msg =
              if new_active, do: gettext("Bot activated."), else: gettext("Bot deactivated.")

            {:noreply,
             socket
             |> put_flash(:info, flash_msg)
             |> reload_bots()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update bot."))}
        end
    end
  end

  @impl true
  def handle_event("reset_errors", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, bot_id} ->
        bot = Bots.get_bot!(bot_id)
        Bots.reset_bot_errors(bot)

        Moderation.log_action(socket.assigns.current_user.id, "reset_bot_errors",
          target_type: "bot",
          target_id: bot_id,
          details: %{"username" => bot.user.username}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Bot error state reset. Re-fetch triggered."))
         |> reload_bots()}
    end
  end

  @impl true
  def handle_event("refresh_favicon", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, bot_id} ->
        bot = Bots.get_bot!(bot_id)
        old_avatar_id = bot.user.avatar_id

        FaviconFetcher.fetch_and_set(bot)

        Moderation.log_action(socket.assigns.current_user.id, "refresh_bot_favicon",
          target_type: "bot",
          target_id: bot_id,
          details: %{"username" => bot.user.username}
        )

        updated_bot = Bots.get_bot!(bot_id)

        if updated_bot.user.avatar_id != nil and updated_bot.user.avatar_id != old_avatar_id do
          {:noreply,
           socket
           |> put_flash(:info, gettext("Bot favicon updated."))
           |> reload_bots()}
        else
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("Could not fetch favicon. Check server logs for details.")
           )
           |> reload_bots()}
        end
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case parse_id(id) do
      :error ->
        {:noreply, socket}

      {:ok, bot_id} ->
        bot = Bots.get_bot!(bot_id)

        case Bots.delete_bot(bot) do
          {:ok, _} ->
            Moderation.log_action(socket.assigns.current_user.id, "delete_bot",
              target_type: "bot",
              target_id: bot_id,
              details: %{"username" => bot.user.username}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Bot deleted successfully."))
             |> reload_bots()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to delete bot."))}
        end
    end
  end

  defp save_new(socket, params) do
    board_ids = parse_board_ids(params["board_ids"])
    attrs = Map.put(params, "board_ids", board_ids)

    case Bots.create_bot(attrs) do
      {:ok, bot} ->
        Moderation.log_action(socket.assigns.current_user.id, "create_bot",
          target_type: "bot",
          target_id: bot.id,
          details: %{"username" => bot.user.username, "feed_url" => bot.feed_url}
        )

        {:noreply,
         socket
         |> assign(show_form: false, editing_bot: nil, form: nil)
         |> put_flash(:info, gettext("Bot created successfully."))
         |> reload_bots()}

      {:error, :role_not_found} ->
        {:noreply,
         put_flash(socket, :error, gettext("User role not found. Please run setup first."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :bot))}
    end
  end

  defp save_edit(socket, params) do
    bot = Bots.get_bot!(socket.assigns.editing_bot.id)
    board_ids = parse_board_ids(params["board_ids"])
    profile_fields = parse_bot_profile_fields(Map.get(params, "profile_fields", %{}))

    attrs =
      params
      |> Map.put("board_ids", board_ids)
      |> Map.put("profile_fields", profile_fields)

    case Bots.update_bot(bot, attrs) do
      {:ok, updated_bot} ->
        Moderation.log_action(socket.assigns.current_user.id, "update_bot",
          target_type: "bot",
          target_id: bot.id,
          details: %{"feed_url" => updated_bot.feed_url}
        )

        {:noreply,
         socket
         |> assign(show_form: false, editing_bot: nil, editing_bot_profile_fields: [], form: nil)
         |> put_flash(:info, gettext("Bot updated successfully."))
         |> reload_bots()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :bot))}
    end
  end

  defp parse_board_ids(nil), do: []

  defp parse_board_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&parse_id/1)
    |> Enum.flat_map(fn
      {:ok, id} -> [id]
      :error -> []
    end)
  end

  defp parse_board_ids(ids) when is_binary(ids) do
    ids
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> parse_board_ids()
  end

  defp reload_bots(socket) do
    assign(socket, :bots, Bots.list_bots())
  end

  defp pad_profile_fields(nil), do: List.duplicate(%{"name" => "", "value" => ""}, 4)

  defp pad_profile_fields(fields) when is_list(fields) do
    empty = %{"name" => "", "value" => ""}
    padded = fields ++ List.duplicate(empty, 4)
    Enum.take(padded, 4)
  end

  defp parse_bot_profile_fields(raw) when is_map(raw) do
    raw
    |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
    |> Enum.map(fn {_, field} ->
      name = Map.get(field, "name", "") |> String.trim()
      value = Map.get(field, "value", "") |> String.trim()
      %{"name" => name, "value" => value}
    end)
    |> Enum.reject(fn %{"name" => name} -> name == "" end)
  end

  defp parse_bot_profile_fields(_), do: []
end
