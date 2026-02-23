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
    title: "Bold",
    action: "wrap",
    before: "**",
    after: "**",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M5.625 3C4.178 3 3 4.178 3 5.625v12.75C3 19.822 4.178 21 5.625 21h5.25a5.632 5.632 0 0 0 4.458-9.16A5.625 5.625 0 0 0 12 3H5.625ZM7.5 7.5h4.5a1.875 1.875 0 1 1 0 3.75H7.5V7.5Zm0 7.5v-3.75h4.5a1.875 1.875 0 0 1 0 3.75H7.5Z" clip-rule="evenodd" /></svg>`,
  },
  {
    label: "I",
    title: "Italic",
    action: "wrap",
    before: "*",
    after: "*",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M10.49 3.388a.75.75 0 0 1 .86-.612l5.25.864a.75.75 0 0 1-.248 1.48l-1.895-.312-3.26 13.544 1.907.314a.75.75 0 0 1-.248 1.48l-5.25-.864a.75.75 0 0 1 .247-1.48l1.896.312 3.26-13.544-1.908-.314a.75.75 0 0 1-.611-.868Z" clip-rule="evenodd" /></svg>`,
  },
  {
    label: "S",
    title: "Strikethrough",
    action: "wrap",
    before: "~~",
    after: "~~",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M5.545 4.843a.75.75 0 0 1 1.057-.098l5.398 4.5 5.398-4.5a.75.75 0 1 1 .959 1.153L13.32 10.1H19.5a.75.75 0 0 1 0 1.5H4.5a.75.75 0 0 1 0-1.5h6.18L5.643 5.9a.75.75 0 0 1-.098-1.057ZM12 13.9l5.357 4.464a.75.75 0 1 1-.959 1.153L12 15.9l-4.398 3.617a.75.75 0 0 1-.959-1.153L12 13.9Z" clip-rule="evenodd" /></svg>`,
  },
  { separator: true },
  {
    label: "H2",
    title: "Heading",
    action: "prefix",
    prefix: "## ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M2.246 3.743a.75.75 0 0 1 .75.75v6.75h9v-6.75a.75.75 0 0 1 1.5 0v15.014a.75.75 0 0 1-1.5 0v-6.764h-9v6.764a.75.75 0 0 1-1.5 0V4.493a.75.75 0 0 1 .75-.75Z" clip-rule="evenodd" /></svg>`,
  },
  {
    label: "Link",
    title: "Link",
    action: "link",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M19.902 4.098a3.75 3.75 0 0 0-5.304 0l-4.5 4.5a3.75 3.75 0 0 0 1.035 6.037.75.75 0 0 1-.646 1.353 5.25 5.25 0 0 1-1.449-8.45l4.5-4.5a5.25 5.25 0 1 1 7.424 7.424l-1.757 1.757a.75.75 0 1 1-1.06-1.06l1.757-1.757a3.75 3.75 0 0 0 0-5.304Zm-7.389 4.267a.75.75 0 0 1 1-.353 5.25 5.25 0 0 1 1.449 8.45l-4.5 4.5a5.25 5.25 0 1 1-7.424-7.424l1.757-1.757a.75.75 0 1 1 1.06 1.06l-1.757 1.757a3.75 3.75 0 1 0 5.304 5.304l4.5-4.5a3.75 3.75 0 0 0-1.035-6.037.75.75 0 0 1-.354-1Z" clip-rule="evenodd" /></svg>`,
  },
  {
    label: "Image",
    title: "Image",
    action: "image",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M1.5 6a2.25 2.25 0 0 1 2.25-2.25h16.5A2.25 2.25 0 0 1 22.5 6v12a2.25 2.25 0 0 1-2.25 2.25H3.75A2.25 2.25 0 0 1 1.5 18V6ZM3 16.06V18c0 .414.336.75.75.75h16.5A.75.75 0 0 0 21 18v-1.94l-2.69-2.689a1.5 1.5 0 0 0-2.12 0l-.88.879.97.97a.75.75 0 1 1-1.06 1.06l-5.16-5.159a1.5 1.5 0 0 0-2.12 0L3 16.061Zm10.125-7.81a1.125 1.125 0 1 1 2.25 0 1.125 1.125 0 0 1-2.25 0Z" clip-rule="evenodd" /></svg>`,
  },
  { separator: true },
  {
    label: "Code",
    title: "Inline Code",
    action: "wrap",
    before: "`",
    after: "`",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M14.447 3.026a.75.75 0 0 1 .527.921l-4.5 16.5a.75.75 0 0 1-1.448-.394l4.5-16.5a.75.75 0 0 1 .921-.527ZM16.72 6.22a.75.75 0 0 1 1.06 0l5.25 5.25a.75.75 0 0 1 0 1.06l-5.25 5.25a.75.75 0 1 1-1.06-1.06L21.44 12l-4.72-4.72a.75.75 0 0 1 0-1.06Zm-9.44 0a.75.75 0 0 1 0 1.06L2.56 12l4.72 4.72a.75.75 0 0 1-1.06 1.06L.97 12.53a.75.75 0 0 1 0-1.06l5.25-5.25a.75.75 0 0 1 1.06 0Z" clip-rule="evenodd" /></svg>`,
  },
  {
    label: "Code Block",
    title: "Code Block",
    action: "block",
    before: "```\n",
    after: "\n```",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M3 6a3 3 0 0 1 3-3h12a3 3 0 0 1 3 3v12a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V6Zm14.25 6a.75.75 0 0 1-.22.53l-2.25 2.25a.75.75 0 1 1-1.06-1.06L15.44 12l-1.72-1.72a.75.75 0 1 1 1.06-1.06l2.25 2.25a.75.75 0 0 1 .22.53Zm-7.28-2.78a.75.75 0 0 1 0 1.06L8.25 12l1.72 1.72a.75.75 0 0 1-1.06 1.06l-2.25-2.25a.75.75 0 0 1 0-1.06l2.25-2.25a.75.75 0 0 1 1.06 0Z" clip-rule="evenodd" /></svg>`,
  },
  { separator: true },
  {
    label: "Quote",
    title: "Blockquote",
    action: "prefix",
    prefix: "> ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M4.848 2.771A49.144 49.144 0 0 1 12 2.25c2.43 0 4.817.178 7.152.52 1.978.292 3.348 2.024 3.348 3.97v6.02c0 1.946-1.37 3.678-3.348 3.97a48.901 48.901 0 0 1-3.476.383.39.39 0 0 0-.297.17l-2.755 4.133a.75.75 0 0 1-1.248 0l-2.755-4.133a.39.39 0 0 0-.297-.17 48.9 48.9 0 0 1-3.476-.384c-1.978-.29-3.348-2.024-3.348-3.97V6.741c0-1.946 1.37-3.68 3.348-3.97ZM6.75 8.25a.75.75 0 0 1 .75-.75h9a.75.75 0 0 1 0 1.5h-9a.75.75 0 0 1-.75-.75Zm.75 2.25a.75.75 0 0 0 0 1.5H12a.75.75 0 0 0 0-1.5H7.5Z" clip-rule="evenodd" /></svg>`,
  },
  {
    label: "List",
    title: "Bullet List",
    action: "prefix",
    prefix: "- ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M2.625 6.75a1.125 1.125 0 1 1 2.25 0 1.125 1.125 0 0 1-2.25 0Zm4.875 0A.75.75 0 0 1 8.25 6h12a.75.75 0 0 1 0 1.5h-12a.75.75 0 0 1-.75-.75ZM2.625 12a1.125 1.125 0 1 1 2.25 0 1.125 1.125 0 0 1-2.25 0ZM7.5 12a.75.75 0 0 1 .75-.75h12a.75.75 0 0 1 0 1.5h-12A.75.75 0 0 1 7.5 12Zm-4.875 5.25a1.125 1.125 0 1 1 2.25 0 1.125 1.125 0 0 1-2.25 0Zm4.875 0a.75.75 0 0 1 .75-.75h12a.75.75 0 0 1 0 1.5h-12a.75.75 0 0 1-.75-.75Z" clip-rule="evenodd" /></svg>`,
  },
  {
    label: "Numbered",
    title: "Numbered List",
    action: "prefix",
    prefix: "1. ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M5.04 3.746a.75.75 0 0 1 .75.75V7.5h.375a.75.75 0 0 1 0 1.5H4.29a.75.75 0 0 1 0-1.5h.375V5.37l-.478.239a.75.75 0 1 1-.67-1.342l1.523-.762ZM7.5 6A.75.75 0 0 1 8.25 5.25h12a.75.75 0 0 1 0 1.5h-12A.75.75 0 0 1 7.5 6Zm0 6a.75.75 0 0 1 .75-.75h12a.75.75 0 0 1 0 1.5h-12A.75.75 0 0 1 7.5 12Zm0 6a.75.75 0 0 1 .75-.75h12a.75.75 0 0 1 0 1.5h-12a.75.75 0 0 1-.75-.75ZM3.195 10.602a1.125 1.125 0 0 1 1.591 1.59l-1.091 1.093h1.43a.75.75 0 0 1 0 1.5H3.09a.75.75 0 0 1-.53-1.28l1.818-1.82a.375.375 0 0 0-.53-.53l-.095.094a.75.75 0 0 1-1.06-1.06l.094-.095Z" clip-rule="evenodd" /></svg>`,
  },
  { separator: true },
  {
    label: "HR",
    title: "Horizontal Rule",
    action: "insert",
    text: "\n---\n",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path fill-rule="evenodd" d="M4.25 12a.75.75 0 0 1 .75-.75h14a.75.75 0 0 1 0 1.5H5a.75.75 0 0 1-.75-.75Z" clip-rule="evenodd" /></svg>`,
  },
];

const PREVIEW_ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path d="M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z" /><path fill-rule="evenodd" d="M1.323 11.447C2.811 6.976 7.028 3.75 12.001 3.75c4.97 0 9.185 3.223 10.675 7.69.12.362.12.752 0 1.113-1.487 4.471-5.705 7.697-10.677 7.697-4.97 0-9.186-3.223-10.675-7.69a1.762 1.762 0 0 1 0-1.113ZM17.25 12a5.25 5.25 0 1 1-10.5 0 5.25 5.25 0 0 1 10.5 0Z" clip-rule="evenodd" /></svg>`;

const WRITE_ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="size-4"><path d="M21.731 2.269a2.625 2.625 0 0 0-3.712 0l-1.157 1.157 3.712 3.712 1.157-1.157a2.625 2.625 0 0 0 0-3.712ZM19.513 8.199l-3.712-3.712-8.4 8.4a5.25 5.25 0 0 0-1.32 2.214l-.8 2.685a.75.75 0 0 0 .933.933l2.685-.8a5.25 5.25 0 0 0 2.214-1.32l8.4-8.4Z" /><path d="M5.25 5.25a3 3 0 0 0-3 3v10.5a3 3 0 0 0 3 3h10.5a3 3 0 0 0 3-3V13.5a.75.75 0 0 0-1.5 0v5.25a1.5 1.5 0 0 1-1.5 1.5H5.25a1.5 1.5 0 0 1-1.5-1.5V8.25a1.5 1.5 0 0 1 1.5-1.5h5.25a.75.75 0 0 0 0-1.5H5.25Z" /></svg>`;

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

    this.toolbar.className = "flex flex-wrap items-center gap-0.5 mb-1";
    this.toolbar.setAttribute("role", "toolbar");
    this.toolbar.setAttribute("aria-label", "Markdown formatting");

    for (const btn of BUTTONS) {
      if (btn.separator) {
        const sep = document.createElement("div");
        sep.className = "w-px h-5 bg-base-300 mx-0.5";
        this.toolbar.appendChild(sep);
        continue;
      }

      const button = document.createElement("button");
      button.type = "button";
      button.className = "btn btn-ghost btn-sm";
      button.title = btn.title;
      button.setAttribute("aria-label", btn.title);
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
      this.previewBtn.title = "Preview";
      this.previewBtn.setAttribute("aria-label", "Preview");
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
          this.previewDiv.innerHTML =
            '<p class="text-error text-sm">Content too large to preview.</p>';
        } else if (payload.html) {
          this.previewDiv.innerHTML = payload.html;
        } else {
          this.previewDiv.innerHTML =
            '<p class="text-base-content/50 text-sm italic">Nothing to preview.</p>';
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
      this.previewBtn.title = "Preview";
      this.previewBtn.setAttribute("aria-label", "Preview");
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
      this.previewBtn.title = "Write";
      this.previewBtn.setAttribute("aria-label", "Write");
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
