/**
 * MarkdownToolbarHook — LiveView JS hook that adds a Markdown formatting
 * toolbar above any textarea it is attached to via `phx-hook="MarkdownToolbarHook"`.
 *
 * All operations are client-side only (selection manipulation + syntax insertion).
 * After each edit an `input` event is dispatched so LiveView picks up the change.
 */

const BUTTONS = [
  {
    label: "B",
    title: "Bold",
    action: "wrap",
    before: "**",
    after: "**",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M6.75 3.744h-.753v8.25h7.125a4.125 4.125 0 0 0 0-8.25H6.75Zm0 0" /><path stroke-linecap="round" stroke-linejoin="round" d="M6.75 12h7.875a4.125 4.125 0 0 1 0 8.25H5.997V12Z" /></svg>`,
  },
  {
    label: "I",
    title: "Italic",
    action: "wrap",
    before: "*",
    after: "*",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M5.248 20.246H9.05m0 0h3.696m-3.696 0 5.893-16.502m0 0h-3.697m3.697 0h3.803" /></svg>`,
  },
  {
    label: "S",
    title: "Strikethrough",
    action: "wrap",
    before: "~~",
    after: "~~",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M12 12h7.5M12 12H4.5m7.5 0V3.75m0 16.5V12" /><line x1="3" y1="12" x2="21" y2="12" stroke-linecap="round" /></svg>`,
  },
  { separator: true },
  {
    label: "H2",
    title: "Heading",
    action: "prefix",
    prefix: "## ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M2.243 4.493v7.5m0 0v7.514m0-7.514h10.5m0 0v-7.5m0 7.5v7.514" /></svg>`,
  },
  {
    label: "Link",
    title: "Link",
    action: "link",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M13.19 8.688a4.5 4.5 0 0 1 1.242 7.244l-4.5 4.5a4.5 4.5 0 0 1-6.364-6.364l1.757-1.757m13.35-.622 1.757-1.757a4.5 4.5 0 0 0-6.364-6.364l-4.5 4.5a4.5 4.5 0 0 0 1.242 7.244" /></svg>`,
  },
  {
    label: "Image",
    title: "Image",
    action: "image",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="m2.25 15.75 5.159-5.159a2.25 2.25 0 0 1 3.182 0l5.159 5.159m-1.5-1.5 1.409-1.409a2.25 2.25 0 0 1 3.182 0l2.909 2.909M3.75 21h16.5A2.25 2.25 0 0 0 22.5 18.75V5.25A2.25 2.25 0 0 0 20.25 3H3.75A2.25 2.25 0 0 0 1.5 5.25v13.5A2.25 2.25 0 0 0 3.75 21Z" /></svg>`,
  },
  { separator: true },
  {
    label: "Code",
    title: "Inline Code",
    action: "wrap",
    before: "`",
    after: "`",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3-4.5 16.5" /></svg>`,
  },
  {
    label: "Code Block",
    title: "Code Block",
    action: "block",
    before: "```\n",
    after: "\n```",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M14.25 9.75 16.5 12l-2.25 2.25m-4.5 0L7.5 12l2.25-2.25M6 20.25h12A2.25 2.25 0 0 0 20.25 18V6A2.25 2.25 0 0 0 18 3.75H6A2.25 2.25 0 0 0 3.75 6v12A2.25 2.25 0 0 0 6 20.25Z" /></svg>`,
  },
  { separator: true },
  {
    label: "Quote",
    title: "Blockquote",
    action: "prefix",
    prefix: "> ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M7.5 8.25h9m-9 3H12m-9.75 1.51c0 1.6 1.123 2.994 2.707 3.227 1.129.166 2.27.293 3.423.379.35.026.67.21.865.501L12 21l2.755-4.133a1.14 1.14 0 0 1 .865-.501 48.172 48.172 0 0 0 3.423-.379c1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z" /></svg>`,
  },
  {
    label: "List",
    title: "Bullet List",
    action: "prefix",
    prefix: "- ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M8.25 6.75h12M8.25 12h12m-12 5.25h12M3.75 6.75h.007v.008H3.75V6.75Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0ZM3.75 12h.007v.008H3.75V12Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm-.375 5.25h.007v.008H3.75v-.008Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Z" /></svg>`,
  },
  {
    label: "Numbered",
    title: "Numbered List",
    action: "prefix",
    prefix: "1. ",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M8.242 5.992h12m-12 6.003h12m-12 5.999h12M4.117 7.495v-3.75H2.99m1.125 3.75H2.99m1.125 0H5.24m-1.92 2.577a1.125 1.125 0 1 1 1.591 1.59l-1.83 1.83h2.16" /></svg>`,
  },
  { separator: true },
  {
    label: "HR",
    title: "Horizontal Rule",
    action: "insert",
    text: "\n---\n",
    icon: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4"><path stroke-linecap="round" stroke-linejoin="round" d="M5 12h14" /></svg>`,
  },
];

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
      button.className = "btn btn-ghost btn-xs";
      button.title = btn.title;
      button.setAttribute("aria-label", btn.title);
      button.innerHTML = btn.icon;

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
  },

  destroyed() {
    if (this.toolbar) {
      this.toolbar.replaceChildren();
    }
  },
};

export default MarkdownToolbarHook;
