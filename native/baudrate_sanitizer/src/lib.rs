use ammonia::{Builder, UrlRelative};
use regex::Regex;
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

static LANGUAGE_CLASS_RE: OnceLock<Regex> = OnceLock::new();

const SAFE_SPAN_CLASSES: &[&str] = &["h-card", "hashtag", "mention", "invisible"];

fn language_class_regex() -> &'static Regex {
    LANGUAGE_CLASS_RE.get_or_init(|| Regex::new(r"^language-[a-zA-Z0-9_+\-]+$").unwrap())
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
    tag_attributes.insert("a", ["href"].into_iter().collect());
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

#[rustler::nif]
fn sanitize_markdown(html: &str) -> String {
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
fn strip_tags(html: &str) -> String {
    Builder::empty()
        .strip_comments(true)
        .clean(html)
        .to_string()
}

rustler::init!("Elixir.Baudrate.Sanitizer.Native");
