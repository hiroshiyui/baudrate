use ammonia::{Builder, UrlRelative};
use regex::Regex;
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

static LANGUAGE_CLASS_RE: OnceLock<Regex> = OnceLock::new();
// Matches <p> elements whose content is entirely whitespace and/or &nbsp; entities —
// these are common artefacts left behind when surrounding <div>/<span> wrappers are
// stripped by Ammonia.
static EMPTY_PARA_RE: OnceLock<Regex> = OnceLock::new();
// Matches runs of three or more consecutive <br> elements, including any
// whitespace / &nbsp; between them.
static EXCESS_BR_RE: OnceLock<Regex> = OnceLock::new();

const SAFE_SPAN_CLASSES: &[&str] = &["h-card", "hashtag", "mention", "invisible"];
const SAFE_ANCHOR_CLASSES: &[&str] = &["hashtag", "mention", "u-url"];

fn language_class_regex() -> &'static Regex {
    LANGUAGE_CLASS_RE.get_or_init(|| Regex::new(r"^language-[a-zA-Z0-9_+\-]+$").unwrap())
}

fn empty_para_regex() -> &'static Regex {
    EMPTY_PARA_RE.get_or_init(|| Regex::new(r"<p>(\s|&nbsp;)*</p>").unwrap())
}

fn excess_br_regex() -> &'static Regex {
    EXCESS_BR_RE.get_or_init(|| Regex::new(r"(<br\s*/?>(\s|&nbsp;)*){3,}").unwrap())
}

fn federation_tags() -> HashSet<&'static str> {
    [
        "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "em", "strong", "del", "code",
        "pre", "blockquote", "ul", "ol", "li", "a", "span",
    ]
    .into_iter()
    .collect()
}

fn clean_content_tags() -> HashSet<&'static str> {
    [
        "script", "style", "iframe", "object", "embed", "form", "input", "textarea", "svg",
        "math",
    ]
    .into_iter()
    .collect()
}

// Each NIF is a one-line wrapper around a plain function, so `cargo test` can
// exercise the rules without a BEAM (Phase 8A).
#[rustler::nif]
fn sanitize_federation(html: &str) -> String {
    federation(html)
}

fn federation(html: &str) -> String {
    let tags = federation_tags();

    let mut tag_attributes: HashMap<&str, HashSet<&str>> = HashMap::new();
    tag_attributes.insert("a", ["href", "class"].into_iter().collect());
    tag_attributes.insert("span", ["class"].into_iter().collect());

    let url_schemes: HashSet<&str> = ["http", "https"].into_iter().collect();

    Builder::new()
        .tags(tags)
        .tag_attributes(tag_attributes)
        .url_schemes(url_schemes)
        .url_relative(UrlRelative::Deny)
        .link_rel(Some("nofollow noopener noreferrer"))
        .clean_content_tags(clean_content_tags())
        .strip_comments(true)
        .attribute_filter(|element, attribute, value| match (element, attribute) {
            ("a", "class") => {
                let filtered: Vec<&str> = value
                    .split_whitespace()
                    .filter(|c| SAFE_ANCHOR_CLASSES.contains(c))
                    .collect();
                if filtered.is_empty() {
                    None
                } else {
                    Some(Cow::Owned(filtered.join(" ")))
                }
            }
            ("span", "class") => {
                let filtered: Vec<&str> = value
                    .split_whitespace()
                    .filter(|c| SAFE_SPAN_CLASSES.contains(c))
                    .collect();
                if filtered.is_empty() {
                    None
                } else {
                    Some(Cow::Owned(filtered.join(" ")))
                }
            }
            _ => Some(Cow::Borrowed(value)),
        })
        .clean(html)
        .to_string()
}

fn sanitize_with_markdown_rules(html: &str) -> String {
    let mut tags = federation_tags();
    for tag in ["table", "thead", "tbody", "tr", "th", "td", "img"] {
        tags.insert(tag);
    }

    let mut tag_attributes: HashMap<&str, HashSet<&str>> = HashMap::new();
    tag_attributes.insert("a", ["href"].into_iter().collect());
    tag_attributes.insert("code", ["class"].into_iter().collect());
    tag_attributes.insert("img", ["src", "alt"].into_iter().collect());

    let url_schemes: HashSet<&str> = ["http", "https", "mailto"].into_iter().collect();

    let re = language_class_regex();

    Builder::new()
        .tags(tags)
        .tag_attributes(tag_attributes)
        .url_schemes(url_schemes)
        .url_relative(UrlRelative::PassThrough)
        .link_rel(Some("nofollow noopener"))
        .clean_content_tags(clean_content_tags())
        .strip_comments(true)
        .attribute_filter(move |element, attribute, value| match (element, attribute) {
            ("code", "class") => {
                if re.is_match(value) {
                    Some(Cow::Borrowed(value))
                } else {
                    None
                }
            }
            // Narrow img src to the forms the Elixir-side rewriter
            // (Baudrate.Media.Rewriter) knows how to handle, so its regex pass
            // is total. In particular this drops PROTOCOL-RELATIVE srcs
            // (`//evil.example/x.png`): url_relative(PassThrough) treats those
            // as relative, so they would slip past a scheme-matching rewrite
            // and still hotlink a third party under a tightened CSP.
            ("img", "src") => {
                if value.starts_with("https://")
                    || value.starts_with("http://")
                    || value.starts_with("/uploads/")
                    || value.starts_with("/media/")
                {
                    Some(Cow::Borrowed(value))
                } else {
                    None
                }
            }
            _ => Some(Cow::Borrowed(value)),
        })
        .clean(html)
        .to_string()
}

#[rustler::nif]
fn sanitize_markdown(html: &str) -> String {
    sanitize_with_markdown_rules(html)
}

const NBSP: &str = "&nbsp;";

#[rustler::nif]
fn strip_tags(html: &str) -> String {
    strip(html)
}

fn strip(html: &str) -> String {
    let text = Builder::empty()
        .strip_comments(true)
        .clean(html)
        .to_string();
    let mut s = text.as_str();
    while let Some(rest) = s.strip_prefix(NBSP) {
        s = rest;
    }
    while let Some(rest) = s.strip_suffix(NBSP) {
        s = rest;
    }
    s.to_string()
}

#[rustler::nif]
fn normalize_feed_html(html: &str) -> String {
    normalize_feed(html)
}

fn normalize_feed(html: &str) -> String {
    // Sanitize with the same allowlist as sanitize_markdown, then clean up
    // common RSS/Atom artefacts produced by stripping disallowed elements.
    let sanitized = sanitize_with_markdown_rules(html);

    // Remove empty <p> elements (e.g. left over from stripped <div> wrappers).
    let cleaned = empty_para_regex().replace_all(&sanitized, "");

    // Collapse runs of 3+ <br> down to two — a common pattern in feed HTML
    // converted from word-processor output or old-style blog generators.
    let cleaned = excess_br_regex().replace_all(&cleaned, "<br><br>");

    // Replace &nbsp; entities with regular spaces.  When the stored HTML is later
    // rendered through Earmark (Markdown.to_html/1), any &nbsp; that appears
    // outside a block-level element is treated as inline Markdown text and its
    // ampersand is HTML-escaped to &amp;, producing the literal string "&nbsp;"
    // in the browser.  Converting to a plain space before storage prevents this.
    let cleaned = cleaned.replace("&nbsp;", " ");

    cleaned.trim().to_string()
}

rustler::init!("Elixir.Baudrate.Sanitizer.Native");

#[cfg(test)]
mod tests {
    use super::*;

    // --- sanitize_federation: remote HTML, the widest attack surface ---

    #[test]
    fn federation_drops_scripts_and_their_content() {
        let out = federation("<p>hi</p><script>alert(1)</script><style>p{}</style>");
        assert_eq!(out, "<p>hi</p>");
    }

    #[test]
    fn federation_drops_event_handlers_and_unknown_attributes() {
        let out = federation(r#"<p onclick="x()" style="color:red">hi</p>"#);
        assert_eq!(out, "<p>hi</p>");
    }

    #[test]
    fn federation_refuses_non_http_link_schemes() {
        for href in ["javascript:alert(1)", "data:text/html,x", "vbscript:x", "/relative"] {
            let out = federation(&format!(r#"<a href="{href}">x</a>"#));
            assert!(!out.contains("href="), "{href} survived: {out}");
        }
    }

    #[test]
    fn federation_keeps_https_links_with_a_safe_rel() {
        let out = federation(r#"<a href="https://example.com/">x</a>"#);
        assert!(out.contains(r#"href="https://example.com/""#));
        assert!(out.contains(r#"rel="nofollow noopener noreferrer""#));
    }

    #[test]
    fn federation_filters_classes_to_the_allow_list() {
        let out = federation(
            r#"<a class="mention evil u-url" href="https://a.example/">@a</a><span class="h-card x">y</span>"#,
        );
        assert!(out.contains(r#"class="mention u-url""#), "{out}");
        assert!(out.contains(r#"<span class="h-card">"#), "{out}");
        assert!(!out.contains("evil"));

        let out = federation(r#"<span class="evil">y</span>"#);
        assert_eq!(out, "<span>y</span>");
    }

    #[test]
    fn federation_drops_images_iframes_and_forms() {
        let out = federation(
            r#"<img src="https://t.example/p.gif"><iframe src="https://x.example"></iframe><form><input></form>ok"#,
        );
        assert_eq!(out, "ok");
    }

    #[test]
    fn federation_strips_comments() {
        assert_eq!(federation("<p>a<!-- hidden --></p>"), "<p>a</p>");
    }

    // --- sanitize_markdown: rendered local Markdown ---

    #[test]
    fn markdown_keeps_only_language_classes_on_code() {
        let out = sanitize_with_markdown_rules(r#"<code class="language-rust">x</code>"#);
        assert!(out.contains(r#"class="language-rust""#));

        let out = sanitize_with_markdown_rules(r#"<code class="evil">x</code>"#);
        assert_eq!(out, "<code>x</code>");
    }

    #[test]
    fn markdown_image_sources_are_the_forms_the_media_rewriter_handles() {
        for src in [
            "https://e.example/a.png",
            "http://e.example/a.png",
            "/uploads/a.webp",
            "/media/sig/enc",
        ] {
            let out = sanitize_with_markdown_rules(&format!(r#"<img src="{src}" alt="a">"#));
            assert!(out.contains(&format!(r#"src="{src}""#)), "{src}: {out}");
        }

        // A protocol-relative src would pass a relative-URL rule and hotlink a
        // third party past the media proxy.
        for src in ["//evil.example/x.png", "javascript:x", "data:image/png;base64,AA", "../x.png"] {
            let out = sanitize_with_markdown_rules(&format!(r#"<img src="{src}">"#));
            assert!(!out.contains("src="), "{src} survived: {out}");
        }
    }

    #[test]
    fn markdown_allows_mailto_but_not_javascript_links() {
        let out = sanitize_with_markdown_rules(r#"<a href="mailto:a@example.com">m</a>"#);
        assert!(out.contains("mailto:a@example.com"));

        let out = sanitize_with_markdown_rules(r#"<a href="javascript:alert(1)">m</a>"#);
        assert!(!out.contains("href="));
    }

    // --- strip_tags and normalize_feed_html ---

    #[test]
    fn strip_removes_markup_and_edge_nbsp() {
        assert_eq!(strip("&nbsp;<b>bold</b> text&nbsp;&nbsp;"), "bold text");
        assert_eq!(strip("<script>x</script>ok"), "ok");
    }

    #[test]
    fn feed_html_loses_empty_paragraphs_and_long_br_runs() {
        let out = normalize_feed("<p> &nbsp; </p><p>a<br><br/><br>b</p>");
        assert_eq!(out, "<p>a<br><br>b</p>");
    }

    #[test]
    fn feed_html_turns_nbsp_into_spaces() {
        assert_eq!(normalize_feed("<p>a&nbsp;b</p>"), "<p>a b</p>");
    }
}
