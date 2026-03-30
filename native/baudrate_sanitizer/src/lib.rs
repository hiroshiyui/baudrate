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

#[rustler::nif]
fn sanitize_federation(html: &str) -> String {
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
