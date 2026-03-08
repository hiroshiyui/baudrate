defmodule BaudrateWeb.InteractionHelpers do
  @moduledoc """
  Shared LiveView helpers for like/boost toggle event handlers.

  Eliminates duplication of toggle-and-update-assigns logic across
  `FeedLive`, `BoardLive`, and `ArticleLive`.
  """

  import Phoenix.LiveView, only: [put_flash: 3]
  import Phoenix.Component, only: [assign: 3]
  use Gettext, backend: BaudrateWeb.Gettext

  @doc """
  Handles a toggle interaction (like or boost) on an item identified by ID,
  updating both a MapSet of active IDs and a counts map in socket assigns.

  ## Parameters

    * `socket` — the LiveView socket
    * `id_string` — the raw ID string from `phx-value-id`
    * `toggle_fn` — `fn user_id, item_id -> {:ok, _} | {:error, atom()} end`
    * `count_fn` — `fn [item_id] -> %{item_id => count} end`
    * `ids_assign` — the assign key for the MapSet (e.g., `:article_liked_ids`)
    * `counts_assign` — the assign key for the counts map (e.g., `:article_like_counts`)
    * `opts` — keyword list with:
      * `:self_error` — the error atom for self-interaction (e.g., `:self_like`)
      * `:self_message` — the flash message for self-interaction
      * `:fail_message` — the flash message for general failure

  """
  def handle_toggle_with_counts(
        socket,
        id_string,
        toggle_fn,
        count_fn,
        ids_assign,
        counts_assign,
        opts
      ) do
    self_error = Keyword.fetch!(opts, :self_error)

    case BaudrateWeb.Helpers.parse_id(id_string) do
      :error ->
        {:noreply, socket}

      {:ok, item_id} ->
        user = socket.assigns.current_user

        case toggle_fn.(user.id, item_id) do
          {:ok, _} ->
            ids = socket.assigns[ids_assign]

            ids =
              if MapSet.member?(ids, item_id),
                do: MapSet.delete(ids, item_id),
                else: MapSet.put(ids, item_id)

            new_counts = count_fn.([item_id])
            new_count = Map.get(new_counts, item_id, 0)
            counts = Map.put(socket.assigns[counts_assign], item_id, new_count)

            {:noreply,
             socket
             |> assign(ids_assign, ids)
             |> assign(counts_assign, counts)}

          {:error, ^self_error} ->
            {:noreply, put_flash(socket, :error, opts[:self_message])}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, opts[:fail_message])}
        end
    end
  end

  @doc """
  Handles a toggle interaction on a feed item (like or boost),
  updating only a MapSet of active IDs (no counts).

  ## Parameters

    * `socket` — the LiveView socket
    * `id_string` — the raw ID string from `phx-value-id`
    * `toggle_fn` — `fn user, feed_item_id -> {:ok, _} | {:error, _} end`
    * `ids_assign` — the assign key for the MapSet (e.g., `:feed_item_liked_ids`)
    * `fail_message` — the flash message for failure

  """
  def handle_toggle_mapset(socket, id_string, toggle_fn, ids_assign, fail_message) do
    case BaudrateWeb.Helpers.parse_id(id_string) do
      :error ->
        {:noreply, socket}

      {:ok, item_id} ->
        user = socket.assigns.current_user

        case toggle_fn.(user, item_id) do
          {:ok, _} ->
            ids = socket.assigns[ids_assign]

            ids =
              if MapSet.member?(ids, item_id),
                do: MapSet.delete(ids, item_id),
                else: MapSet.put(ids, item_id)

            {:noreply, assign(socket, ids_assign, ids)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, fail_message)}
        end
    end
  end

  @doc """
  Returns standard options for article like toggle.
  """
  def article_like_opts do
    [
      self_error: :self_like,
      self_message: gettext("You cannot like your own article."),
      fail_message: gettext("Failed to toggle like.")
    ]
  end

  @doc """
  Returns standard options for article boost toggle.
  """
  def article_boost_opts do
    [
      self_error: :self_boost,
      self_message: gettext("You cannot boost your own article."),
      fail_message: gettext("Failed to toggle boost.")
    ]
  end

  @doc """
  Returns standard options for comment like toggle.
  """
  def comment_like_opts do
    [
      self_error: :self_like,
      self_message: gettext("You cannot like your own comment."),
      fail_message: gettext("Failed to toggle like.")
    ]
  end

  @doc """
  Returns standard options for comment boost toggle.
  """
  def comment_boost_opts do
    [
      self_error: :self_boost,
      self_message: gettext("You cannot boost your own comment."),
      fail_message: gettext("Failed to toggle boost.")
    ]
  end
end
