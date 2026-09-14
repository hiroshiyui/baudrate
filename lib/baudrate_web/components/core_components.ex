defmodule BaudrateWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: BaudrateWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Returns a human-friendly display name for a user or remote actor.
  Delegates to `BaudrateWeb.Helpers.display_name/1`.
  """
  defdelegate display_name(entity), to: BaudrateWeb.Helpers

  @doc "Returns the best profile URL for a remote actor. See `BaudrateWeb.Helpers.remote_actor_profile_url/1`."
  defdelegate remote_actor_profile_url(actor), to: BaudrateWeb.Helpers

  @doc "Whether to render a like/boost toggle. See `BaudrateWeb.Helpers.interaction_toggle?/3`."
  defdelegate interaction_toggle?(user, author_id, active), to: BaudrateWeb.Helpers

  @doc "Whether the user is a moved, read-only account. See `BaudrateWeb.Helpers.moved_account?/1`."
  defdelegate moved_account?(user), to: BaudrateWeb.Helpers

  @doc "Formats a datetime in the site's configured timezone. See `BaudrateWeb.Helpers.format_datetime/2`."
  defdelegate format_datetime(datetime, format), to: BaudrateWeb.Helpers

  @doc "Formats a datetime in the site's configured timezone with default format. See `BaudrateWeb.Helpers.format_datetime/1`."
  defdelegate format_datetime(datetime), to: BaudrateWeb.Helpers

  @doc "Returns an ISO datetime string for HTML datetime attribute. See `BaudrateWeb.Helpers.datetime_attr/1`."
  defdelegate datetime_attr(datetime), to: BaudrateWeb.Helpers

  @doc "Formats date only (no time). See `BaudrateWeb.Helpers.format_date/1`."
  defdelegate format_date(datetime), to: BaudrateWeb.Helpers

  @doc "Returns the canonical display timestamp for an article (published_at || inserted_at). See `BaudrateWeb.Helpers.article_datetime/1`."
  defdelegate article_datetime(article), to: BaudrateWeb.Helpers

  @doc "Returns the fediverse handle for a local user or board. See `BaudrateWeb.Helpers.fediverse_handle/1`."
  defdelegate fediverse_handle(entity), to: BaudrateWeb.Helpers

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="flash-message toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button
          type="button"
          class="flash-close group self-start cursor-pointer"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-5 opacity-60 group-hover:opacity-90" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={["core-button", @class]} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={["core-button", @class]} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"
  attr :label_class, :any, default: nil, doc: "additional CSS classes for the label text"

  attr :toolbar, :boolean,
    default: false,
    doc: "when true, attaches a Markdown formatting toolbar above the textarea"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input class="core-input-hidden" type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="core-field core-field-checkbox fieldset mb-2">
      <label>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class={["label", @label_class]}>
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={["core-checkbox", @class || "checkbox checkbox-sm"]}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@errors != [] && "#{@id}-error"}
            {@rest}
          />{@label}
        </span>
      </label>
      <div :if={@errors != []} class="core-field-error" id={"#{@id}-error"} role="alert">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="core-field core-field-select fieldset mb-2">
      <label>
        <span :if={@label} class={["label mb-1", @label_class]}>{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            "core-select",
            @class || "w-full select",
            @errors != [] && (@error_class || "select-error")
          ]}
          multiple={@multiple}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-error"}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <div :if={@errors != []} class="core-field-error" id={"#{@id}-error"} role="alert">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="core-field core-field-textarea fieldset mb-2">
      <%!-- The <label> holds only the label text. The textarea, Markdown
           preview region and JS-populated toolbar are siblings, so the
           toolbar buttons and preview content never leak into the
           textarea's accessible name and clicks on them are not
           redirected to the textarea. --%>
      <label
        :if={@label}
        for={@id}
        class={["core-field-label core-textarea-label label mb-1", @label_class]}
      >
        {@label}
      </label>
      <div
        :if={@toolbar}
        id={"#{@id}-hashtag-wrap"}
        phx-hook="HashtagAutocompleteHook"
        data-i18n-suggestions={gettext("Suggestions: %{count}", count: "%{count}")}
        class="relative"
      >
        <textarea
          id={@id}
          name={@name}
          phx-hook="MarkdownToolbarHook"
          class={[
            "core-textarea",
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-error"}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </div>
      <div
        :if={@toolbar}
        id={"#{@id}-md-preview"}
        class="hidden w-full prose prose-sm max-w-none border border-base-300 rounded-lg p-3 min-h-[6rem] bg-base-100"
        phx-update="ignore"
        role="region"
        aria-label={gettext("Markdown preview")}
      >
      </div>
      <div
        :if={@toolbar}
        id={"#{@id}-md-toolbar"}
        phx-update="ignore"
        data-i18n={
          Jason.encode!(%{
            bold: gettext("Bold"),
            italic: gettext("Italic"),
            strikethrough: gettext("Strikethrough"),
            heading: gettext("Heading"),
            link: gettext("Link"),
            image: gettext("Image"),
            inline_code: gettext("Inline Code"),
            code_block: gettext("Code Block"),
            blockquote: gettext("Blockquote"),
            bullet_list: gettext("Bullet List"),
            numbered_list: gettext("Numbered List"),
            horizontal_rule: gettext("Horizontal Rule"),
            preview: gettext("Preview"),
            write: gettext("Write"),
            toolbar_label: gettext("Markdown formatting"),
            nothing_to_preview: gettext("Nothing to preview."),
            content_too_large: gettext("Content too large to preview."),
            expand_toolbar: gettext("Expand toolbar"),
            collapse_toolbar: gettext("Collapse toolbar")
          })
        }
      >
      </div>
      <textarea
        :if={!@toolbar}
        id={@id}
        name={@name}
        class={[
          "core-textarea",
          @class || "w-full textarea",
          @errors != [] && (@error_class || "textarea-error")
        ]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && "#{@id}-error"}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <div :if={@errors != []} class="core-field-error" id={"#{@id}-error"} role="alert">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="core-field fieldset mb-2">
      <label>
        <span :if={@label} class={["label mb-1", @label_class]}>{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            "core-input",
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-error"}
          {@rest}
        />
      </label>
      <div :if={@errors != []} class="core-field-error" id={"#{@id}-error"} role="alert">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="core-field-error-message mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" aria-hidden="true" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions
  attr :id, :string, default: nil

  def header(assigns) do
    ~H"""
    <header
      id={@id}
      class={["core-header", @actions != [] && "flex items-center justify-between gap-6", "pb-4"]}
    >
      <div>
        <h1 class="core-header-title text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="core-header-subtitle text-sm text-base-content/80">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="core-header-actions flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="core-table table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col} scope="col">{col[:label]}</th>
          <th :if={@action != []} scope="col">
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody
        class="core-table-body"
        id={@id}
        phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
      >
        <tr :for={row <- @rows} class="core-table-row" id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  attr :id, :string, default: nil

  def list(assigns) do
    ~H"""
    <ul id={@id} class="core-list list">
      <li :for={item <- @item} class="core-list-item list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"
  attr :rest, :global

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" {@rest} />
    """
  end

  @doc """
  Renders a user avatar.

  Shows the uploaded avatar image if available, otherwise falls back to
  a DaisyUI circle with the first letter of the username.

  ## Examples

      <.avatar user={@current_user} size={120} />
      <.avatar user={@current_user} size={48} />
      <.avatar user={@current_user} size={36} />
  """
  attr :user, :map, required: true
  attr :size, :integer, default: 48, values: [120, 48, 36, 24]
  attr :class, :string, default: nil

  attr :decorative, :boolean,
    default: false,
    doc:
      "when true the avatar is hidden from assistive technology (empty alt, no role/label); " <>
        "use when the user's name is rendered as visible text right next to it"

  def avatar(%{user: %{avatar_id: avatar_id}} = assigns) when is_binary(avatar_id) do
    assigns = assign(assigns, :url, Baudrate.Avatar.avatar_url(avatar_id, assigns.size))

    ~H"""
    <div class={[
      "core-avatar",
      "avatar",
      @class
    ]}>
      <div class={size_class(@size)}>
        <img src={@url} alt={if @decorative, do: "", else: display_name(@user)} />
      </div>
    </div>
    """
  end

  def avatar(assigns) do
    name = assigns.user.display_name || assigns.user.username
    assigns = assign(assigns, :initial, String.first(name) |> String.upcase())

    ~H"""
    <div
      class={[
        "core-avatar avatar avatar-placeholder",
        @class
      ]}
      role={if !@decorative, do: "img"}
      aria-label={if !@decorative, do: display_name(@user)}
      aria-hidden={if @decorative, do: "true"}
    >
      <div class={["bg-neutral text-neutral-content", size_class(@size)]}>
        <span
          aria-hidden="true"
          class={
            cond do
              @size == 120 -> "text-4xl"
              @size == 48 -> "text-lg"
              @size == 36 -> "text-sm"
              true -> "text-xs"
            end
          }
        >
          {@initial}
        </span>
      </div>
    </div>
    """
  end

  defp size_class(120), do: "w-[120px] rounded-full"
  defp size_class(48), do: "w-12 rounded-full"
  defp size_class(36), do: "w-9 rounded-full"
  defp size_class(24), do: "w-6 rounded-full"

  @doc """
  Renders a pagination control using DaisyUI join buttons.

  Uses `patch` navigation so LiveView updates without full reload. After the
  page changes, `BaudrateWeb.PaginationScrollHook` scrolls to `scroll_target`
  (an element id) or, without one, to the page's `[data-focus-target]`.

  ## Examples

      <.pagination page={@page} total_pages={@total_pages} path={~p"/boards/general"} params={%{}} />
  """
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :path, :string, required: true
  attr :params, :map, default: %{}

  attr :scroll_target, :string,
    default: nil,
    doc:
      "id of the element to scroll to after a page change (default: the page's data-focus-target)"

  def pagination(assigns) do
    assigns = assign(assigns, :page_range, pagination_range(assigns.page, assigns.total_pages))

    ~H"""
    <nav
      :if={@total_pages > 1}
      aria-label={gettext("Pagination")}
      class="pagination-nav flex justify-center mt-6"
      data-scroll-target={@scroll_target}
    >
      <div class="join">
        <.link
          :if={@page > 1}
          patch={"#{@path}?#{URI.encode_query(Map.put(@params, "page", @page - 1))}"}
          class="pagination-prev join-item btn btn-sm"
          aria-label={gettext("Previous page")}
        >
          &laquo;
        </.link>
        <button
          :if={@page <= 1}
          disabled
          class="pagination-prev join-item btn btn-sm"
          aria-label={gettext("Previous page")}
        >
          &laquo;
        </button>

        <%= for p <- @page_range do %>
          <.link
            :if={p != @page}
            patch={"#{@path}?#{URI.encode_query(Map.put(@params, "page", p))}"}
            class="pagination-page join-item btn btn-sm"
            aria-label={gettext("Page %{number}", number: p)}
          >
            {p}
          </.link>
          <span
            :if={p == @page}
            class="pagination-current join-item btn btn-sm btn-active"
            aria-current="page"
          >
            <span class="pagination-current-label sr-only">
              {gettext("Page %{number}", number: p)}
            </span>
            <span class="pagination-current-number" aria-hidden="true">{p}</span>
          </span>
        <% end %>

        <.link
          :if={@page < @total_pages}
          patch={"#{@path}?#{URI.encode_query(Map.put(@params, "page", @page + 1))}"}
          class="pagination-next join-item btn btn-sm"
          aria-label={gettext("Next page")}
        >
          &raquo;
        </.link>
        <button
          :if={@page >= @total_pages}
          disabled
          class="pagination-next join-item btn btn-sm"
          aria-label={gettext("Next page")}
        >
          &raquo;
        </button>
      </div>
    </nav>
    """
  end

  defp pagination_range(_current, total) when total <= 7, do: Enum.to_list(1..total)

  defp pagination_range(current, total) do
    start = max(current - 3, 1)
    finish = min(start + 6, total)
    start = max(finish - 6, 1)
    Enum.to_list(start..finish)
  end

  @doc """
  Renders a report modal dialog.

  Displays a DaisyUI modal with target info, a reason textarea, and
  submit/cancel buttons. Controlled by the `show` assign.

  ## Examples

      <.report_modal
        show={@show_report_modal}
        target_type={@report_target_type}
        target_label={@report_target_label}
        on_close="close_report_modal"
        on_submit="submit_report"
      />
  """
  attr :show, :boolean, required: true
  attr :target_type, :string, default: nil
  attr :target_label, :string, default: nil
  attr :on_close, :string, required: true
  attr :on_submit, :string, required: true

  def report_modal(assigns) do
    title =
      case assigns.target_type do
        "article" -> gettext("Report Article")
        "comment" -> gettext("Report Comment")
        "user" -> gettext("Report User")
        "feed_item" -> gettext("Report Post")
        "message" -> gettext("Report Message")
        "remote_actor" -> gettext("Report Account")
        _ -> gettext("Report")
      end

    assigns = assign(assigns, :title, title)

    ~H"""
    <div
      :if={@show}
      id="report-modal"
      class="report-modal modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby="report-modal-title"
      phx-hook="FocusTrapHook"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <div class="report-modal-box modal-box">
        <h3 id="report-modal-title" class="report-modal-title font-bold text-lg">{@title}</h3>
        <p :if={@target_label} class="report-modal-target text-sm text-base-content/70 mt-1 truncate">
          {@target_label}
        </p>
        <.form for={%{}} phx-submit={@on_submit} class="report-modal-form mt-4">
          <label for="report-reason" class="label">
            <span class="label-text">{gettext("Reason")}</span>
          </label>
          <textarea
            id="report-reason"
            name="reason"
            class="report-modal-reason textarea textarea-bordered w-full"
            rows="4"
            required
            maxlength="2000"
            placeholder={gettext("Please describe the issue...")}
          ></textarea>
          <div class="modal-action">
            <button type="button" phx-click={@on_close} class="report-modal-cancel btn">
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="report-modal-submit btn btn-error"
              phx-disable-with={gettext("Submitting...")}
            >
              {gettext("Report")}
            </button>
          </div>
        </.form>
      </div>
      <div class="report-modal-backdrop modal-backdrop" phx-click={@on_close}></div>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Renders the hint under a TOTP code field that each code works once.

  Codes are consumed on use (ADR 0024), so two checks within the same
  30 seconds need two codes. The hint is always shown, never only after a
  failure: showing it for a reused code would tell whoever is guessing that
  the rest of the form was right. Point the input's `aria-describedby` at `id`.
  """
  attr :id, :string, required: true

  def totp_code_hint(assigns) do
    ~H"""
    <p id={@id} class="totp-code-hint text-xs text-base-content/70 mt-1">
      {gettext("Each code works only once. If you just used one, wait for the next code.")}
    </p>
    """
  end

  @doc """
  Renders the password policy checklist with a strength meter.

  `strength` is the map returned by `BaudrateWeb.Helpers.password_strength/1`
  (`:length`, `:lowercase`, `:uppercase`, `:digit`, `:special`). Met and unmet
  states are conveyed by icon, colour, and an `sr-only` "Met:"/"Not met:"
  prefix, so colour is never the only signal.
  """
  attr :id, :string, default: "password-strength"
  attr :class, :any, default: nil, doc: "extra classes, e.g. spacing"
  attr :strength, :map, required: true

  def password_requirements(assigns) do
    assigns =
      assign(assigns,
        items: [
          {:length, gettext("At least 12 characters")},
          {:lowercase, gettext("Contains a lowercase letter")},
          {:uppercase, gettext("Contains an uppercase letter")},
          {:digit, gettext("Contains a digit")},
          {:special, gettext("Contains a special character")}
        ],
        met: Enum.count(Map.values(assigns.strength), & &1)
      )

    ~H"""
    <div id={@id} class={["password-requirements space-y-1", @class]}>
      <p class="password-requirements-title text-sm font-medium">
        {gettext("Password requirements:")}
      </p>
      <ul class="password-requirements-list text-sm space-y-0.5">
        <li
          :for={{key, label} <- @items}
          id={"#{@id}-#{key}"}
          class="password-requirement flex items-center gap-1.5"
        >
          <.icon
            name={if @strength[key], do: "hero-check-circle-mini", else: "hero-x-circle-mini"}
            class={["size-4", if(@strength[key], do: "text-success", else: "text-error")]}
            aria-hidden="true"
          />
          <span class="sr-only">
            {if @strength[key], do: gettext("Met:"), else: gettext("Not met:")}
          </span>
          {label}
        </li>
      </ul>
      <progress
        id={"#{@id}-meter"}
        class={[
          "password-requirements-meter progress w-full",
          cond do
            @met <= 1 -> "progress-error"
            @met <= 3 -> "progress-warning"
            true -> "progress-success"
          end
        ]}
        value={@met}
        max="5"
        aria-label={gettext("Password strength")}
        aria-valuetext={
          cond do
            @met <= 1 -> gettext("Weak")
            @met <= 3 -> gettext("Fair")
            true -> gettext("Strong")
          end
        }
      ></progress>
    </div>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(BaudrateWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(BaudrateWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Renders a link preview card for Open Graph metadata.

  Displays a card with the preview image (if available), title, description,
  and domain. For YouTube URLs, renders an embedded video player using the
  privacy-enhanced `youtube-nocookie.com` domain. For failed previews, shows
  a minimal card with just the URL and domain.

  ## Attributes

    * `preview` — a `%LinkPreview{}` struct (required)
  """
  attr :preview, :map, required: true

  def link_preview(%{preview: %{status: status, url: url}} = assigns)
      when status in ["fetched", "failed"] do
    case extract_youtube_video_id(url) do
      nil -> link_preview_card(assigns)
      video_id -> link_preview_youtube(assign(assigns, :video_id, video_id))
    end
  end

  def link_preview(assigns), do: ~H""

  defp link_preview_youtube(assigns) do
    ~H"""
    <div class="link-preview-card link-preview-youtube not-prose mt-3 max-w-lg">
      <div class="aspect-video rounded-lg overflow-hidden border border-base-300">
        <iframe
          src={"https://www.youtube-nocookie.com/embed/#{@video_id}"}
          title={@preview.title || gettext("YouTube video")}
          class="link-preview-video w-full h-full"
          frameborder="0"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
          allowfullscreen
          loading="lazy"
          referrerpolicy="strict-origin"
        ></iframe>
      </div>
      <div :if={@preview.title && @preview.status == "fetched"} class="mt-1.5">
        <a
          href={@preview.url}
          target="_blank"
          rel="nofollow noopener noreferrer"
          class="link-preview-title text-sm font-medium link link-hover line-clamp-1"
        >
          {@preview.title}
        </a>
      </div>
    </div>
    """
  end

  defp link_preview_card(%{preview: %{status: "failed"}} = assigns) do
    ~H"""
    <a
      href={@preview.url}
      target="_blank"
      rel="nofollow noopener noreferrer"
      class="link-preview-card link-preview-failed card bg-base-200 not-prose overflow-hidden border border-base-300 mt-3 max-w-lg block"
      aria-label={gettext("Link preview")}
    >
      <div class="card-body p-3">
        <span class="link-preview-url text-sm text-base-content/70 truncate">{@preview.url}</span>
        <span class="link-preview-domain text-xs text-base-content/50">{@preview.domain}</span>
      </div>
    </a>
    """
  end

  defp link_preview_card(%{preview: %{status: "fetched"}} = assigns) do
    ~H"""
    <a
      href={@preview.url}
      target="_blank"
      rel="nofollow noopener noreferrer"
      class="link-preview-card link-preview-fetched card card-side bg-base-200 not-prose overflow-hidden border border-base-300 mt-3 max-w-lg"
      aria-label={gettext("Link preview: %{title}", title: @preview.title || @preview.url)}
    >
      <figure :if={@preview.image_path} class="link-preview-figure w-32 shrink-0">
        <img
          src={@preview.image_path}
          alt={gettext("Preview image for %{title}", title: @preview.title || @preview.url)}
          class="link-preview-image object-cover h-full w-full"
          loading="lazy"
          referrerpolicy="no-referrer"
        />
      </figure>
      <div class="card-body p-3">
        <h3 :if={@preview.title} class="link-preview-title card-title text-sm line-clamp-1">
          {@preview.title}
        </h3>
        <p
          :if={@preview.description}
          class="link-preview-description text-xs text-base-content/70 line-clamp-2"
        >
          {@preview.description}
        </p>
        <span class="link-preview-domain text-xs text-base-content/50">{@preview.domain}</span>
      </div>
    </a>
    """
  end

  defp link_preview_card(assigns), do: ~H""

  @youtube_url_pattern ~r/^https?:\/\/(?:www\.|m\.)?(?:youtube\.com\/watch\?.*v=|youtu\.be\/|youtube\.com\/embed\/|youtube\.com\/shorts\/)([a-zA-Z0-9_-]{11})/

  @doc false
  def extract_youtube_video_id(url) when is_binary(url) do
    case Regex.run(@youtube_url_pattern, url) do
      [_, video_id] -> video_id
      _ -> nil
    end
  end

  def extract_youtube_video_id(_), do: nil
end
