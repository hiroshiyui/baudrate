/**
 * MarkdownToolbarHook — LiveView JS hook that adds a Markdown formatting
 * toolbar above any textarea it is attached to via `phx-hook="MarkdownToolbarHook"`.
 *
 * All formatting operations are client-side only (selection manipulation + syntax
 * insertion). After each edit an `input` event is dispatched so LiveView picks
 * up the change.
 *
 * A Write/Preview toggle sends the textarea content to the server for rendering
 * via `pushEvent("markdown_preview", ...)` with a reply callback.
 */

const BUTTONS = [
  {
    label: "B",
    titleKey: "bold",
    action: "wrap",
    before: "**",
    after: "**",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linejoin="round" d="M6.75 3.744h-.753v8.25h7.125a4.125 4.125 0 0 0 0-8.25H6.75Zm0 0v.38m0 16.122h6.747a4.5 4.5 0 0 0 0-9.001h-7.5v9h.753Zm0 0v-.37m0-15.751h6a3.75 3.75 0 1 1 0 7.5h-6m0-7.5v7.5m0 0v8.25m0-8.25h6.375a4.125 4.125 0 0 1 0 8.25H6.75m.747-15.38h4.875a3.375 3.375 0 0 1 0 6.75H7.497v-6.75Zm0 7.5h5.25a3.75 3.75 0 0 1 0 7.5h-5.25v-7.5Z"/></svg>`,
  },
  {
    label: "I",
    titleKey: "italic",
    action: "wrap",
    before: "*",
    after: "*",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M5.248 20.246H9.05m0 0h3.696m-3.696 0 5.893-16.502m0 0h-3.697m3.697 0h3.803"/></svg>`,
  },
  {
    label: "S",
    titleKey: "strikethrough",
    action: "wrap",
    before: "~~",
    after: "~~",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M12 12a8.912 8.912 0 0 1-.318-.079c-1.585-.424-2.904-1.247-3.76-2.236-.873-1.009-1.265-2.19-.968-3.301.59-2.2 3.663-3.29 6.863-2.432A8.186 8.186 0 0 1 16.5 5.21M6.42 17.81c.857.99 2.176 1.812 3.761 2.237 3.2.858 6.274-.23 6.863-2.431.233-.868.044-1.779-.465-2.617M3.75 12h16.5"/></svg>`,
  },
  { separator: true },
  {
    label: "H2",
    titleKey: "heading",
    action: "prefix",
    prefix: "## ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M21.75 19.5H16.5v-1.609a2.25 2.25 0 0 1 1.244-2.012l2.89-1.445c.651-.326 1.116-.955 1.116-1.683 0-.498-.04-.987-.118-1.463-.135-.825-.835-1.422-1.668-1.489a15.202 15.202 0 0 0-3.464.12M2.243 4.492v7.5m0 0v7.502m0-7.501h10.5m0-7.5v7.5m0 0v7.501"/></svg>`,
  },
  {
    label: "Link",
    titleKey: "link",
    action: "link",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M13.19 8.688a4.5 4.5 0 0 1 1.242 7.244l-4.5 4.5a4.5 4.5 0 0 1-6.364-6.364l1.757-1.757m13.35-.622 1.757-1.757a4.5 4.5 0 0 0-6.364-6.364l-4.5 4.5a4.5 4.5 0 0 0 1.242 7.244"/></svg>`,
  },
  {
    label: "Image",
    titleKey: "image",
    action: "image",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="m2.25 15.75 5.159-5.159a2.25 2.25 0 0 1 3.182 0l5.159 5.159m-1.5-1.5 1.409-1.409a2.25 2.25 0 0 1 3.182 0l2.909 2.909m-18 3.75h16.5a1.5 1.5 0 0 0 1.5-1.5V6a1.5 1.5 0 0 0-1.5-1.5H3.75A1.5 1.5 0 0 0 2.25 6v12a1.5 1.5 0 0 0 1.5 1.5Zm10.5-11.25h.008v.008h-.008V8.25Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Z"/></svg>`,
  },
  { separator: true },
  {
    label: "Code",
    titleKey: "inline_code",
    action: "wrap",
    before: "`",
    after: "`",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3-4.5 16.5"/></svg>`,
  },
  {
    label: "Code Block",
    titleKey: "code_block",
    action: "block",
    before: "```\n",
    after: "\n```",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M14.25 9.75 16.5 12l-2.25 2.25m-4.5 0L7.5 12l2.25-2.25M6 20.25h12A2.25 2.25 0 0 0 20.25 18V6A2.25 2.25 0 0 0 18 3.75H6A2.25 2.25 0 0 0 3.75 6v12A2.25 2.25 0 0 0 6 20.25Z"/></svg>`,
  },
  { separator: true },
  {
    label: "Quote",
    titleKey: "blockquote",
    action: "prefix",
    prefix: "> ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M7.5 8.25h9m-9 3H12m-9.75 1.51c0 1.6 1.123 2.994 2.707 3.227 1.129.166 2.27.293 3.423.379.35.026.67.21.865.501L12 21l2.755-4.133a1.14 1.14 0 0 1 .865-.501 48.172 48.172 0 0 0 3.423-.379c1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z"/></svg>`,
  },
  {
    label: "List",
    titleKey: "bullet_list",
    action: "prefix",
    prefix: "- ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M8.25 6.75h12M8.25 12h12m-12 5.25h12M3.75 6.75h.007v.008H3.75V6.75Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0ZM3.75 12h.007v.008H3.75V12Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm-.375 5.25h.007v.008H3.75v-.008Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Z"/></svg>`,
  },
  {
    label: "Numbered",
    titleKey: "numbered_list",
    action: "prefix",
    prefix: "1. ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M8.242 5.992h12m-12 6.003H20.24m-12 5.999h12M4.117 7.495v-3.75H2.99m1.125 3.75H2.99m1.125 0H5.24m-1.92 2.577a1.125 1.125 0 1 1 1.591 1.59l-1.83 1.83h2.16M2.99 15.745h1.125a1.125 1.125 0 0 1 0 2.25H3.74m0-.002h.375a1.125 1.125 0 0 1 0 2.25H2.99"/></svg>`,
  },
  { separator: true },
  {
    label: "HR",
    titleKey: "horizontal_rule",
    action: "insert",
    text: "\n---\n",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M5 12h14"/></svg>`,
  },
];

const PREVIEW_ICON = `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/></svg>`;

const WRITE_ICON = `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125M18 14v4.75A2.25 2.25 0 0 1 15.75 21H5.25A2.25 2.25 0 0 1 3 18.75V8.25A2.25 2.25 0 0 1 5.25 6H10"/></svg>`;

const SPINNER_HTML = `<span class="loading loading-spinner loading-sm"></span>`;

function getLineRange(text, start, end) {
  const lineStart = text.lastIndexOf("\n", start - 1) + 1;
  let lineEnd = text.indexOf("\n", end);
  if (lineEnd === -1) lineEnd = text.length;
  return { lineStart, lineEnd };
}

function applyWrap(textarea, before, after) {
  const { selectionStart: start, selectionEnd: end, value } = textarea;
  const selected = value.slice(start, end);
  const replacement = before + (selected || "text") + after;
  textarea.setRangeText(replacement, start, end, "end");
  if (!selected) {
    textarea.selectionStart = start + before.length;
    textarea.selectionEnd = start + before.length + 4; // "text"
  }
}

function applyBlock(textarea, before, after) {
  const { selectionStart: start, selectionEnd: end, value } = textarea;
  const selected = value.slice(start, end);
  const replacement = before + (selected || "code") + after;
  textarea.setRangeText(replacement, start, end, "end");
  if (!selected) {
    textarea.selectionStart = start + before.length;
    textarea.selectionEnd = start + before.length + 4; // "code"
  }
}

function applyPrefix(textarea, prefix) {
  const { selectionStart: start, selectionEnd: end, value } = textarea;
  const { lineStart, lineEnd } = getLineRange(value, start, end);
  const lines = value.slice(lineStart, lineEnd).split("\n");
  const prefixed = lines.map((l) => prefix + l).join("\n");
  textarea.setRangeText(prefixed, lineStart, lineEnd, "end");
  textarea.selectionStart = lineStart;
  textarea.selectionEnd = lineStart + prefixed.length;
}

function applyLink(textarea) {
  const { selectionStart: start, selectionEnd: end, value } = textarea;
  const selected = value.slice(start, end);
  const replacement = "[" + (selected || "text") + "](url)";
  textarea.setRangeText(replacement, start, end, "end");
  if (selected) {
    // Place cursor on "url"
    textarea.selectionStart = start + selected.length + 2;
    textarea.selectionEnd = start + selected.length + 5;
  } else {
    // Select "text"
    textarea.selectionStart = start + 1;
    textarea.selectionEnd = start + 5;
  }
}

function applyImage(textarea) {
  const { selectionStart: start, selectionEnd: end, value } = textarea;
  const selected = value.slice(start, end);
  const replacement = "![" + (selected || "alt") + "](url)";
  textarea.setRangeText(replacement, start, end, "end");
  if (selected) {
    textarea.selectionStart = start + selected.length + 3;
    textarea.selectionEnd = start + selected.length + 6;
  } else {
    textarea.selectionStart = start + 2;
    textarea.selectionEnd = start + 5;
  }
}

function applyInsert(textarea, text) {
  const { selectionStart: start, selectionEnd: end } = textarea;
  textarea.setRangeText(text, start, end, "end");
}

function dispatchInput(textarea) {
  textarea.dispatchEvent(new Event("input", { bubbles: true }));
}

const MarkdownToolbarHook = {
  mounted() {
    // The server renders a <div id="<textarea-id>-md-toolbar" phx-update="ignore">
    // next to the textarea. We populate it once; LiveView will never patch it.
    this.toolbar = document.getElementById(this.el.id + "-md-toolbar");
    this.previewDiv = document.getElementById(this.el.id + "-md-preview");
    this.isPreview = false;
    this.formatButtons = [];

    if (!this.toolbar) return;

    // Parse i18n strings from server (with English fallback)
    try {
      this.i18n = JSON.parse(this.toolbar.dataset.i18n || "{}");
    } catch {
      this.i18n = {};
    }

    this.toolbar.className = "flex flex-wrap items-center gap-0.5 mb-1";
    this.toolbar.setAttribute("role", "toolbar");
    this.toolbar.setAttribute(
      "aria-label",
      this.i18n.toolbar_label || "Markdown formatting",
    );

    for (const btn of BUTTONS) {
      if (btn.separator) {
        const sep = document.createElement("div");
        sep.className = "w-px h-5 bg-base-300 mx-0.5";
        this.toolbar.appendChild(sep);
        continue;
      }

      const button = document.createElement("button");
      const title = this.i18n[btn.titleKey] || btn.titleKey;
      button.type = "button";
      button.className = "btn btn-ghost btn-sm";
      button.title = title;
      button.setAttribute("aria-label", title);
      button.innerHTML = btn.icon;
      this.formatButtons.push(button);

      button.addEventListener("click", (e) => {
        e.preventDefault();
        this.el.focus();

        switch (btn.action) {
          case "wrap":
            applyWrap(this.el, btn.before, btn.after);
            break;
          case "block":
            applyBlock(this.el, btn.before, btn.after);
            break;
          case "prefix":
            applyPrefix(this.el, btn.prefix);
            break;
          case "link":
            applyLink(this.el);
            break;
          case "image":
            applyImage(this.el);
            break;
          case "insert":
            applyInsert(this.el, btn.text);
            break;
        }

        dispatchInput(this.el);
      });

      this.toolbar.appendChild(button);
    }

    // Preview toggle button — pushed to the right with ml-auto
    if (this.previewDiv) {
      const spacer = document.createElement("div");
      spacer.className = "ml-auto";
      this.toolbar.appendChild(spacer);

      this.previewBtn = document.createElement("button");
      this.previewBtn.type = "button";
      this.previewBtn.className = "btn btn-ghost btn-sm";
      this.previewBtn.title = this.i18n.preview || "Preview";
      this.previewBtn.setAttribute("aria-label", this.i18n.preview || "Preview");
      this.previewBtn.setAttribute("aria-pressed", "false");
      this.previewBtn.innerHTML = PREVIEW_ICON;

      this.previewBtn.addEventListener("click", (e) => {
        e.preventDefault();
        this.togglePreview();
      });

      this.toolbar.appendChild(this.previewBtn);

      // Listen for server-pushed preview results
      this.handleEvent("markdown_preview_result", (payload) => {
        if (!this.isPreview) return;

        if (payload.error) {
          const msg =
            this.i18n.content_too_large || "Content too large to preview.";
          this.previewDiv.innerHTML = `<p class="text-error text-sm">${msg}</p>`;
        } else if (payload.html) {
          this.previewDiv.innerHTML = payload.html;
        } else {
          const msg =
            this.i18n.nothing_to_preview || "Nothing to preview.";
          this.previewDiv.innerHTML = `<p class="text-base-content/70 text-sm italic">${msg}</p>`;
        }
      });
    }
  },

  togglePreview() {
    if (this.isPreview) {
      // Switch to Write mode
      this.isPreview = false;
      this.el.classList.remove("hidden");
      this.previewDiv.classList.add("hidden");
      this.previewBtn.innerHTML = PREVIEW_ICON;
      this.previewBtn.title = this.i18n.preview || "Preview";
      this.previewBtn.setAttribute(
        "aria-label",
        this.i18n.preview || "Preview",
      );
      this.previewBtn.setAttribute("aria-pressed", "false");
      this.setFormatButtonsDisabled(false);
      this.el.focus();
    } else {
      // Switch to Preview mode
      this.isPreview = true;
      this.el.classList.add("hidden");
      this.previewDiv.classList.remove("hidden");
      this.previewDiv.innerHTML = SPINNER_HTML;
      this.previewBtn.innerHTML = WRITE_ICON;
      this.previewBtn.title = this.i18n.write || "Write";
      this.previewBtn.setAttribute("aria-label", this.i18n.write || "Write");
      this.previewBtn.setAttribute("aria-pressed", "true");
      this.setFormatButtonsDisabled(true);

      this.pushEvent("markdown_preview", { body: this.el.value });
    }
  },

  setFormatButtonsDisabled(disabled) {
    for (const btn of this.formatButtons) {
      btn.disabled = disabled;
      if (disabled) {
        btn.classList.add("btn-disabled");
      } else {
        btn.classList.remove("btn-disabled");
      }
    }
  },

  updated() {
    // Re-apply hidden state if LiveView re-patches while in preview mode
    if (this.isPreview) {
      this.el.classList.add("hidden");
      if (this.previewDiv) {
        this.previewDiv.classList.remove("hidden");
      }
    }
  },

  destroyed() {
    if (this.toolbar) {
      this.toolbar.replaceChildren();
    }
    this.isPreview = false;
    this.formatButtons = [];
    this.previewBtn = null;
    this.previewDiv = null;
  },
};

export default MarkdownToolbarHook;
