defmodule BaudrateWeb.ModerationComponents do
  @moduledoc """
  Shared display of a report, used by the admin queue (`/admin/moderation`)
  and the board moderators' queue (`/moderation`), so the two cannot drift
  apart. The pages differ in what they may do with a report, not in how a
  report reads.
  """

  use Phoenix.Component
  use Gettext, backend: BaudrateWeb.Gettext

  import BaudrateWeb.CoreComponents, only: [author_link: 1]

  import BaudrateWeb.Helpers,
    only: [
      datetime_attr: 1,
      display_name: 1,
      format_datetime: 1,
      translate_report_category: 1,
      translate_report_status: 1
    ]

  use Phoenix.VerifiedRoutes,
    endpoint: BaudrateWeb.Endpoint,
    router: BaudrateWeb.Router,
    statics: BaudrateWeb.static_paths()

  @doc """
  One report: status, category, who reported it and when, their reason, the
  reported content or account with a link to it, how it was handled, and the
  resolve and dismiss controls while it is open.

  The page handles `resolve`, `dismiss` and (when `allow_delete`)
  `delete_content`; `prefix` namespaces every id, so both queues can use the
  ids in tests and scripts.
  """
  attr :report, :map, required: true
  attr :others, :integer, default: 0, doc: "other open reports about the same target"
  attr :prefix, :string, required: true, doc: "id prefix for this page"
  attr :allow_delete, :boolean, default: false, doc: "may delete the reported content"
  attr :allow_flag, :boolean, default: false, doc: "may send a Flag to the remote instance"

  attr :allow_instance_actions, :boolean,
    default: false,
    doc: "may reach the instance page, where suspending the actor and blocking the domain live"

  def report_card(assigns) do
    ~H"""
    <div class="card-body">
      <div class="flex justify-between items-start">
        <div>
          <span class={[
            "badge badge-sm",
            @report.status == "open" && "badge-warning",
            @report.status == "resolved" && "badge-success",
            @report.status == "dismissed" && "badge-ghost"
          ]}>
            {translate_report_status(@report.status)}
          </span>
          <span
            id={"#{@prefix}-report-category-#{@report.id}"}
            class="moderation-report-category badge badge-sm badge-outline ml-2"
          >
            {translate_report_category(@report.category)}
          </span>
          <%!-- Which rule the reporter cited (P1-D9). Rules are retired rather
          than deleted, so this still resolves for an old report. --%>
          <span
            :if={@report.rule}
            id={"#{@prefix}-report-rule-#{@report.id}"}
            class="moderation-report-rule badge badge-sm badge-outline ml-2 max-w-full truncate"
            title={@report.rule.title}
          >
            {@report.rule.title}
          </span>
          <span class="text-sm opacity-70 ml-2">
            <time datetime={datetime_attr(@report.inserted_at)}>
              {format_datetime(@report.inserted_at)}
            </time>
          </span>
          <span
            :if={@others > 0}
            id={"#{@prefix}-report-others-#{@report.id}"}
            class="moderation-report-others badge badge-sm badge-warning ml-2"
          >
            {ngettext(
              "%{count} other open report on this target",
              "%{count} other open reports on this target",
              @others
            )}
          </span>
        </div>
        <div
          :if={@report.reporter}
          id={"#{@prefix}-report-reporter-#{@report.id}"}
          class="moderation-report-reporter text-sm opacity-70"
        >
          {gettext("Reported by %{name}", name: display_name(@report.reporter))}
        </div>
        <div
          :if={@report.reporter_remote_actor}
          id={"#{@prefix}-report-remote-reporter-#{@report.id}"}
          class="moderation-report-remote-reporter text-sm opacity-70"
        >
          {gettext("Reported from %{domain} by %{name}",
            domain: @report.reporter_remote_actor.domain,
            name: display_name(@report.reporter_remote_actor)
          )}
        </div>
      </div>

      <%!-- A report a content filter opened rather than a person (ADR 0065).
      `reason` holds the pattern as it stood when it matched. --%>
      <p
        :if={@report.content_filter_id}
        id={"#{@prefix}-report-filter-#{@report.id}"}
        class="moderation-report-filter mt-2 text-sm break-words"
      >
        {gettext("Reported automatically: it matched the filter “%{pattern}”.",
          pattern: @report.reason
        )}
      </p>

      <div :if={is_nil(@report.content_filter_id)} class="moderation-report-reason mt-2">
        <p class="font-semibold">{gettext("Reason:")}</p>
        <p :if={@report.reason != ""} class="whitespace-pre-wrap break-words">{@report.reason}</p>
        <p
          :if={@report.reason == ""}
          id={"#{@prefix}-report-no-reason-#{@report.id}"}
          class="moderation-report-no-reason italic opacity-70"
        >
          {gettext("No reason given.")}
        </p>
      </div>

      <%!-- Reported Content --%>
      <div
        :if={@report.article}
        class="moderation-report-article mt-2 p-3 bg-base-300 rounded-lg"
      >
        <p class="text-sm font-semibold">{gettext("Reported Article:")}</p>
        <.link
          id={"#{@prefix}-report-article-link-#{@report.id}"}
          navigate={~p"/articles/#{@report.article.slug}"}
          class="moderation-report-article-link link link-primary break-words"
        >
          {@report.article.title}
        </.link>
        <p class="moderation-report-article-body text-sm whitespace-pre-wrap break-words max-h-64 overflow-y-auto mt-1">
          {@report.article.body}
        </p>
        <p
          :if={@report.article.deleted_at && @report.evidence_body}
          id={"#{@prefix}-report-article-evidence-#{@report.id}"}
          class="moderation-report-evidence text-sm whitespace-pre-wrap break-words max-h-64 overflow-y-auto mt-1 opacity-80"
        >
          {gettext("Removed content, kept for 90 days:")}
          {@report.evidence_body}
        </p>
        <button
          :if={@allow_delete and @report.status == "open" and is_nil(@report.article.deleted_at)}
          id={"#{@prefix}-delete-article-#{@report.id}"}
          class="moderation-delete-article btn btn-error btn-sm mt-1"
          phx-click="delete_content"
          phx-value-type="article"
          phx-value-id={@report.article.id}
          phx-value-report={@report.id}
          data-confirm={gettext("Delete this article?")}
          aria-label={gettext("Delete Article: %{title}", title: @report.article.title)}
        >
          {gettext("Delete Article")}
        </button>
      </div>

      <div
        :if={@report.comment}
        class="moderation-report-comment mt-2 p-3 bg-base-300 rounded-lg"
      >
        <p class="text-sm font-semibold">{gettext("Reported Comment:")}</p>
        <p class="moderation-report-comment-body text-sm whitespace-pre-wrap break-words max-h-64 overflow-y-auto">
          {@report.comment.body}
        </p>
        <p
          :if={@report.comment.deleted_at && @report.evidence_body}
          id={"#{@prefix}-report-comment-evidence-#{@report.id}"}
          class="moderation-report-evidence text-sm whitespace-pre-wrap break-words max-h-64 overflow-y-auto opacity-80"
        >
          {gettext("Removed content, kept for 90 days:")}
          {@report.evidence_body}
        </p>
        <.link
          :if={@report.comment.article}
          id={"#{@prefix}-report-comment-link-#{@report.id}"}
          navigate={BaudrateWeb.Helpers.comment_link(@report.comment.article, @report.comment, nil)}
          class="moderation-report-comment-link link link-primary text-sm"
        >
          {gettext("View in context")}
        </.link>
        <button
          :if={@allow_delete and @report.status == "open" and is_nil(@report.comment.deleted_at)}
          id={"#{@prefix}-delete-comment-#{@report.id}"}
          class="moderation-delete-comment btn btn-error btn-sm mt-1"
          phx-click="delete_content"
          phx-value-type="comment"
          phx-value-id={@report.comment.id}
          phx-value-report={@report.id}
          data-confirm={gettext("Delete this comment?")}
          aria-label={gettext("Delete Comment from report #%{id}", id: @report.id)}
        >
          {gettext("Delete Comment")}
        </button>
      </div>

      <div
        :if={@report.timeline_item}
        id={"#{@prefix}-report-feed-item-#{@report.id}"}
        class="moderation-report-feed-item mt-2 p-3 bg-base-300 rounded-lg"
      >
        <p class="text-sm font-semibold">{gettext("Reported Timeline Item:")}</p>
        <p
          :if={@report.timeline_item.title}
          class="moderation-report-feed-item-title break-words"
        >
          {@report.timeline_item.title}
        </p>
        <p class="moderation-report-feed-item-body text-sm whitespace-pre-wrap break-words max-h-64 overflow-y-auto">
          {@report.timeline_item.body}
        </p>
        <a
          :if={@report.timeline_item.source_url}
          id={"#{@prefix}-report-feed-item-link-#{@report.id}"}
          href={@report.timeline_item.source_url}
          target="_blank"
          rel="noopener noreferrer nofollow"
          class="moderation-report-feed-item-link link link-primary text-sm break-all"
        >
          {gettext("View original")}
        </a>
      </div>

      <div
        :if={@report.message_id || @report.message_body}
        id={"#{@prefix}-report-message-#{@report.id}"}
        class="moderation-report-message mt-2 p-3 bg-base-300 rounded-lg"
      >
        <p class="text-sm font-semibold">{gettext("Reported Direct Message:")}</p>
        <p class="moderation-report-message-body text-sm whitespace-pre-wrap break-words">
          {@report.message_body}
        </p>
        <p class="moderation-report-message-note text-xs opacity-70 mt-1">
          {gettext("Only this message was shared with moderators, not the conversation.")}
        </p>
      </div>

      <div
        :if={@report.remote_actor}
        class="moderation-report-actor mt-2 p-3 bg-base-300 rounded-lg"
      >
        <p class="text-sm font-semibold">{gettext("Reported Actor:")}</p>
        <a
          id={"#{@prefix}-report-actor-link-#{@report.id}"}
          href={@report.remote_actor.url || @report.remote_actor.ap_id}
          target="_blank"
          rel="noopener noreferrer nofollow"
          class="moderation-report-actor-link link link-primary font-mono text-sm break-all"
        >
          {@report.remote_actor.ap_id}
        </a>
        <p class="text-sm opacity-70">
          {display_name(@report.remote_actor)}@{@report.remote_actor.domain}
        </p>
        <p :if={@allow_instance_actions} class="moderation-report-actor-actions mt-2 text-sm">
          <.link
            id={"#{@prefix}-report-instance-link-#{@report.id}"}
            navigate={~p"/admin/federation/instances/#{@report.remote_actor.domain}"}
            class="moderation-report-instance-link link link-primary"
          >
            {gettext("Suspend this account or block %{domain}",
              domain: @report.remote_actor.domain
            )}
          </.link>
        </p>
      </div>

      <div
        :if={@report.reported_user}
        class="moderation-report-user mt-2 p-3 bg-base-300 rounded-lg"
      >
        <p class="text-sm font-semibold">{gettext("Reported User:")}</p>
        <p>
          <.author_link
            user={@report.reported_user}
            id={"#{@prefix}-report-user-link-#{@report.id}"}
            class="moderation-report-user-link link link-primary"
          >
            {display_name(@report.reported_user)}
          </.author_link>
          <span class="text-sm opacity-70">(@{@report.reported_user.username})</span>
        </p>
        <%!-- A flagged timeline reply has no page here, so its report keeps a
        copy of the text (ADR 0065). --%>
        <p
          :if={
            @report.content_filter_id && @report.evidence_body && is_nil(@report.article) &&
              is_nil(@report.comment)
          }
          id={"#{@prefix}-report-user-evidence-#{@report.id}"}
          class="moderation-report-evidence text-sm whitespace-pre-wrap break-words max-h-64 overflow-y-auto mt-1"
        >
          {gettext("The reply that matched, kept for 90 days after this report is closed:")}
          {@report.evidence_body}
        </p>
      </div>

      <%!-- Resolution Info --%>
      <div
        :if={@report.status in ["resolved", "dismissed"] and @report.resolved_by}
        id={"#{@prefix}-report-handled-by-#{@report.id}"}
        class="moderation-report-handled-by mt-2 text-sm opacity-70"
      >
        {if @report.resolution_note,
          do:
            gettext("Handled by %{name} — %{note}",
              name: display_name(@report.resolved_by),
              note: @report.resolution_note
            ),
          else: gettext("Handled by %{name}", name: display_name(@report.resolved_by))}
      </div>

      <%!-- Send Flag to Remote --%>
      <div :if={@allow_flag and @report.status == "open" and @report.remote_actor} class="mt-2">
        <button
          id={"#{@prefix}-send-flag-#{@report.id}"}
          class="moderation-send-flag btn btn-warning btn-sm"
          phx-click="send_flag"
          phx-value-id={@report.id}
          data-confirm={
            gettext("Send a Flag report to %{domain}?", domain: @report.remote_actor.domain)
          }
        >
          {gettext("Send Flag to %{domain}", domain: @report.remote_actor.domain)}
        </button>
      </div>

      <%!-- Actions --%>
      <div :if={@report.status == "open"} class="card-actions justify-end mt-4">
        <form
          id={"#{@prefix}-resolve-form-#{@report.id}"}
          class="moderation-resolve-form flex gap-2 items-end"
          phx-submit="resolve"
        >
          <input type="hidden" name="report_id" value={@report.id} />
          <input
            id={"#{@prefix}-resolve-note-#{@report.id}"}
            class="moderation-resolve-note input input-bordered input-sm w-64"
            type="text"
            name="note"
            placeholder={gettext("Resolution note (optional)")}
            aria-label={gettext("Resolution note for report #%{id}", id: @report.id)}
          />
          <button
            id={"#{@prefix}-resolve-submit-#{@report.id}"}
            class="moderation-resolve-submit btn btn-success btn-sm"
            type="submit"
            phx-disable-with={gettext("Resolving...")}
            aria-label={gettext("Resolve report #%{id}", id: @report.id)}
          >
            {gettext("Resolve")}
          </button>
        </form>
        <button
          id={"#{@prefix}-dismiss-#{@report.id}"}
          class="moderation-dismiss btn btn-ghost btn-sm"
          phx-click="dismiss"
          phx-value-id={@report.id}
          aria-label={gettext("Dismiss report #%{id}", id: @report.id)}
        >
          {gettext("Dismiss")}
        </button>
      </div>
    </div>
    """
  end
end
