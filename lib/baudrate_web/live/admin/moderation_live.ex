defmodule BaudrateWeb.Admin.ModerationLive do
  @moduledoc """
  LiveView for the moderation queue.

  Accessible to both admin and moderator roles. Displays content
  reports with filtering, resolution, and dismissal actions.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Moderation
  import BaudrateWeb.Helpers, only: [parse_id: 1, translate_report_status: 1]

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user.role.name not in ["admin", "moderator"] do
      {:ok,
       socket
       |> put_flash(:error, gettext("Access denied."))
       |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(status_filter: "open")
       |> assign(page_title: gettext("Admin Moderation"))
       |> load_reports()}
    end
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(status_filter: status)
     |> load_reports()}
  end

  @impl true
  def handle_event("resolve", %{"report_id" => id, "note" => note}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, report_id} -> do_resolve(socket, report_id, note)
    end
  end

  @impl true
  def handle_event("dismiss", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, report_id} -> do_dismiss(socket, report_id)
    end
  end

  @impl true
  def handle_event("delete_content", %{"type" => "article", "id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, article_id} -> do_delete_article(socket, article_id)
    end
  end

  @impl true
  def handle_event("delete_content", %{"type" => "comment", "id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, comment_id} -> do_delete_comment(socket, comment_id)
    end
  end

  @impl true
  def handle_event("send_flag", %{"id" => id}, socket) do
    case parse_id(id) do
      :error -> {:noreply, socket}
      {:ok, report_id} -> do_send_flag(socket, report_id)
    end
  end

  defp do_resolve(socket, report_id, note) do
    report = Moderation.get_report!(report_id)

    case Moderation.resolve_report(report, socket.assigns.current_user.id, note) do
      {:ok, _} ->
        Moderation.log_action(socket.assigns.current_user.id, "resolve_report",
          target_type: "report",
          target_id: report.id,
          details: %{"note" => note}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Report resolved."))
         |> load_reports()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to resolve report."))}
    end
  end

  defp do_dismiss(socket, report_id) do
    report = Moderation.get_report!(report_id)

    case Moderation.dismiss_report(report, socket.assigns.current_user.id) do
      {:ok, _} ->
        Moderation.log_action(socket.assigns.current_user.id, "dismiss_report",
          target_type: "report",
          target_id: report.id
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Report dismissed."))
         |> load_reports()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to dismiss report."))}
    end
  end

  defp do_delete_article(socket, article_id) do
    article = Baudrate.Repo.get!(Content.Article, article_id)

    case Content.soft_delete_article(article) do
      {:ok, _} ->
        Moderation.log_action(socket.assigns.current_user.id, "delete_article",
          target_type: "article",
          target_id: article.id,
          details: %{"title" => article.title}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Article deleted."))
         |> load_reports()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete article."))}
    end
  end

  defp do_delete_comment(socket, comment_id) do
    comment = Baudrate.Repo.get!(Content.Comment, comment_id)

    case Content.soft_delete_comment(comment) do
      {:ok, _} ->
        Moderation.log_action(socket.assigns.current_user.id, "delete_comment",
          target_type: "comment",
          target_id: comment.id
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Comment deleted."))
         |> load_reports()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete comment."))}
    end
  end

  defp do_send_flag(socket, report_id) do
    report = Moderation.get_report!(report_id)

    if report.remote_actor do
      content_ap_ids =
        []
        |> then(fn ids ->
          if report.article && report.article.ap_id, do: [report.article.ap_id | ids], else: ids
        end)
        |> then(fn ids ->
          if report.comment && report.comment.ap_id, do: [report.comment.ap_id | ids], else: ids
        end)

      flag = Baudrate.Federation.Publisher.build_flag(report.remote_actor, content_ap_ids, report.reason)
      Baudrate.Federation.Delivery.deliver_flag(flag, report.remote_actor)

      {:noreply, put_flash(socket, :info, gettext("Flag sent to %{domain}.", domain: report.remote_actor.domain))}
    else
      {:noreply, put_flash(socket, :error, gettext("No remote actor to send flag to."))}
    end
  end

  defp load_reports(socket) do
    reports = Moderation.list_reports(status: socket.assigns.status_filter)
    assign(socket, reports: reports)
  end
end
