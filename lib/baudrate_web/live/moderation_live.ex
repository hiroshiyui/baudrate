defmodule BaudrateWeb.ModerationLive do
  @moduledoc """
  The report queue for board moderators (`/moderation`), part of Phase 1B.

  Board moderators are ordinary members (role `user`), so this page lives
  outside `/admin` and shows only what they may act on: reports about articles
  in the boards they moderate and comments on those articles. Never reports
  about accounts, direct messages or feed items, and never another board's.

  The scope is `Content.moderated_board_ids/1` (every board for staff, so an
  admin sees the same page as a lighter view of `/admin/moderation`). Every
  action re-checks that the report is in scope
  (`Moderation.report_in_boards?/2`) and that the member may delete the
  content (`Content.can_delete_article?/2`, `can_delete_comment?/3`), because
  the report id comes from the client.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.{Content, Moderation}
  alias Baudrate.Notification.Hooks

  import BaudrateWeb.Helpers, only: [parse_id: 1, parse_page: 1, translate_report_status: 1]

  @statuses ~w(open resolved dismissed)

  @impl true
  def mount(_params, _session, socket) do
    case Content.moderated_board_ids(socket.assigns.current_user) do
      [] ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You do not moderate any boards."))
         |> redirect(to: ~p"/")}

      board_ids ->
        {:ok,
         assign(socket,
           board_ids: board_ids,
           status_filter: "open",
           page: 1,
           total_pages: 1,
           reports: [],
           other_reports: %{},
           page_title: gettext("Moderation")
         )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"], else: "open"

    {:noreply,
     socket
     |> assign(status_filter: status, page: parse_page(params["page"]))
     |> load_reports()}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: ~p"/moderation?status=#{status}")}
  end

  @impl true
  def handle_event("resolve", %{"report_id" => id, "note" => note}, socket) do
    with_report(socket, id, fn report ->
      case Moderation.resolve_report(report, socket.assigns.current_user.id, note) do
        {:ok, resolved} ->
          log(socket, "resolve_report", report)
          Hooks.notify_report_reviewed(resolved)
          {:noreply, socket |> put_flash(:info, gettext("Report resolved.")) |> load_reports()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to resolve report."))}
      end
    end)
  end

  @impl true
  def handle_event("dismiss", %{"id" => id}, socket) do
    with_report(socket, id, fn report ->
      case Moderation.dismiss_report(report, socket.assigns.current_user.id) do
        {:ok, _} ->
          log(socket, "dismiss_report", report)
          {:noreply, socket |> put_flash(:info, gettext("Report dismissed.")) |> load_reports()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to dismiss report."))}
      end
    end)
  end

  @impl true
  def handle_event("delete_content", %{"type" => "article", "id" => id} = params, socket) do
    user = socket.assigns.current_user

    with {:ok, article_id} <- parse_id(id),
         %{} = article <- Content.get_article(article_id),
         true <- Content.can_delete_article?(user, article) do
      if report = report(socket, params), do: Moderation.capture_evidence(report, article.body)

      case Content.soft_delete_article(article, deleted_by: user.id) do
        {:ok, _} ->
          Hooks.notify_content_removed(article, user.id, reason_category(socket, params))

          Moderation.log_action(user.id, "delete_article",
            target_type: "article",
            target_id: article.id,
            details: %{"title" => article.title}
          )

          {:noreply, socket |> put_flash(:info, gettext("Article deleted.")) |> load_reports()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to delete article."))}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Article not found."))}
    end
  end

  @impl true
  def handle_event("delete_content", %{"type" => "comment", "id" => id} = params, socket) do
    user = socket.assigns.current_user

    with {:ok, comment_id} <- parse_id(id),
         %{} = comment <- Content.get_comment(comment_id),
         %{} = article <- Content.get_article(comment.article_id),
         true <- Content.can_delete_comment?(user, comment, article) do
      if report = report(socket, params), do: Moderation.capture_evidence(report, comment.body)

      case Content.soft_delete_comment(comment, deleted_by: user.id) do
        {:ok, _} ->
          Hooks.notify_content_removed(comment, user.id, reason_category(socket, params))

          Moderation.log_action(user.id, "delete_comment",
            target_type: "comment",
            target_id: comment.id
          )

          {:noreply, socket |> put_flash(:info, gettext("Comment deleted.")) |> load_reports()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to delete comment."))}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Comment not found."))}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # A report id from the client is only acted on when it is about one of the
  # boards this member moderates.
  defp with_report(socket, id, fun) do
    with {:ok, report_id} <- parse_id(id),
         report <- Moderation.get_report(report_id),
         true <- report != nil,
         true <- Moderation.report_in_boards?(report, socket.assigns.board_ids) do
      fun.(report)
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Report not found."))}
    end
  end

  # The reason the author is told, taken from the report this deletion was made
  # from. Only a report already on this page counts, so the value never comes
  # from the client.
  defp reason_category(socket, params) do
    case report(socket, params) do
      %{category: category} -> category
      nil -> nil
    end
  end

  defp report(socket, params) do
    with id when is_binary(id) <- params["report"],
         {:ok, report_id} <- parse_id(id) do
      Enum.find(socket.assigns.reports, &(&1.id == report_id))
    else
      _ -> nil
    end
  end

  defp log(socket, action, report) do
    Moderation.log_action(socket.assigns.current_user.id, action,
      target_type: "report",
      target_id: report.id
    )
  end

  defp load_reports(socket) do
    %{reports: reports, page: page, total_pages: total_pages} =
      Moderation.paginate_reports(
        status: socket.assigns.status_filter,
        page: socket.assigns.page,
        boards: socket.assigns.board_ids
      )

    assign(socket,
      reports: reports,
      page: page,
      total_pages: total_pages,
      other_reports: Moderation.other_open_report_counts(reports)
    )
  end
end
