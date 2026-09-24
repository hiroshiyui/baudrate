use scraper::{Html, Selector};
use std::collections::HashSet;
use url::Url;

#[derive(rustler::NifStruct)]
#[module = "Baudrate.HtmlParser.Native.OgMetadata"]
struct OgMetadata {
    title: Option<String>,
    description: Option<String>,
    image_url: Option<String>,
    site_name: Option<String>,
}

// Each NIF is a one-line wrapper around a plain function, so `cargo test` can
// exercise the rules without a BEAM (Phase 8A).

/// Parse an HTML document and extract Open Graph / Twitter Card / fallback metadata.
#[rustler::nif]
fn parse_og_metadata(html: &str) -> OgMetadata {
    og_metadata(html)
}

fn og_metadata(html: &str) -> OgMetadata {
    let document = Html::parse_document(html);

    let title = find_meta_property(&document, "og:title")
        .or_else(|| find_meta_name(&document, "twitter:title"))
        .or_else(|| find_tag_text(&document, "title"));

    let description = find_meta_property(&document, "og:description")
        .or_else(|| find_meta_name(&document, "twitter:description"))
        .or_else(|| find_meta_name(&document, "description"));

    let image_url = find_meta_property(&document, "og:image")
        .or_else(|| find_meta_name(&document, "twitter:image"));

    let site_name = find_meta_property(&document, "og:site_name");

    OgMetadata {
        title,
        description,
        image_url,
        site_name,
    }
}

/// Every external link in an HTML fragment, in document order, each as it was
/// written and as a browser would resolve it against `origin`.
///
/// A link is resolved rather than read as text because a browser resolves it:
/// `//spam.example/x`, `/\spam.example/x` and `http:spam.example` all leave the
/// site, and a check that looked for an `https://` prefix counted none of them.
/// Same-site is a **host** comparison, not a prefix one, so
/// `https://example.org.spam.example/` is not mistaken for `https://example.org`.
///
/// Skipped: fragment-only and empty hrefs, links classed `hashtag` or `mention`
/// (remote content marks its own tag and profile links that way), anything that
/// does not resolve to http(s), and anything on `origin`'s host.
fn external_links(html: &str, origin: &str) -> Vec<(String, Url)> {
    let base = match Url::parse(origin) {
        Ok(base) => base,
        Err(_) => return Vec::new(),
    };

    let fragment = Html::parse_fragment(html);
    let selector = Selector::parse("a[href]").unwrap();
    let mut links = Vec::new();

    for element in fragment.select(&selector) {
        let href = match element.value().attr("href") {
            Some(h) if !h.trim().is_empty() => h,
            _ => continue,
        };

        if href.trim_start().starts_with('#') {
            continue;
        }

        let classes = element.value().attr("class").unwrap_or("");
        if classes.contains("hashtag") || classes.contains("mention") {
            continue;
        }

        let mut resolved = match base.join(href) {
            Ok(url) => url,
            Err(_) => continue,
        };

        if resolved.scheme() != "http" && resolved.scheme() != "https" {
            continue;
        }

        if resolved.host_str().is_none() || resolved.host_str() == base.host_str() {
            continue;
        }

        resolved.set_fragment(None);
        links.push((href.to_string(), resolved));
    }

    links
}

/// Every distinct external URL in an HTML fragment, resolved and without its
/// fragment, in document order. See `external_links/2` for what counts.
#[rustler::nif]
fn extract_urls(html: &str, origin: &str) -> Vec<String> {
    urls(html, origin)
}

fn urls(html: &str, origin: &str) -> Vec<String> {
    let mut seen = HashSet::new();

    external_links(html, origin)
        .into_iter()
        .map(|(_, resolved)| resolved.to_string())
        .filter(|url| seen.insert(url.clone()))
        .collect()
}

/// The first external URL in an HTML fragment — the first of `extract_urls/2`,
/// so the two never disagree about what an external link is.
///
/// Returned as written when it is already an absolute http(s) URL, so a link
/// preview shows `https://例え.jp/` rather than its punycode; resolved
/// otherwise, because `//host/path` is not something a fetcher can use.
#[rustler::nif]
fn extract_first_url(html: &str, origin: &str) -> Option<String> {
    first_url(html, origin)
}

fn first_url(html: &str, origin: &str) -> Option<String> {
    external_links(html, origin)
        .into_iter()
        .next()
        .map(|(href, resolved)| {
            let lower = href.trim().to_ascii_lowercase();

            if lower.starts_with("http://") || lower.starts_with("https://") {
                href.trim().to_string()
            } else {
                resolved.to_string()
            }
        })
}

/// The number of `<img>` elements in an HTML fragment.
#[rustler::nif]
fn count_images(html: &str) -> usize {
    images(html)
}

fn images(html: &str) -> usize {
    let fragment = Html::parse_fragment(html);
    let selector = Selector::parse("img").unwrap();
    fragment.select(&selector).count()
}

fn find_meta_property(document: &Html, property: &str) -> Option<String> {
    let selector_str = format!("meta[property=\"{}\"]", property);
    let selector = Selector::parse(&selector_str).ok()?;

    document
        .select(&selector)
        .next()
        .and_then(|el| el.value().attr("content"))
        .map(|s| s.to_string())
}

fn find_meta_name(document: &Html, name: &str) -> Option<String> {
    let selector_str = format!("meta[name=\"{}\"]", name);
    let selector = Selector::parse(&selector_str).ok()?;

    document
        .select(&selector)
        .next()
        .and_then(|el| el.value().attr("content"))
        .map(|s| s.to_string())
}

fn find_tag_text(document: &Html, tag: &str) -> Option<String> {
    let selector = Selector::parse(tag).ok()?;

    document.select(&selector).next().map(|el| {
        el.text()
            .collect::<Vec<_>>()
            .join("")
            .trim()
            .to_string()
    })
}

rustler::init!("Elixir.Baudrate.HtmlParser.Native");

#[cfg(test)]
mod tests {
    use super::*;

    const ORIGIN: &str = "https://example.org";

    // --- extract_urls: what the limits on new accounts and the filters count ---

    #[test]
    fn links_that_leave_the_site_are_counted_however_they_are_written() {
        let html = r#"<a href="//spam.example/a">1</a><a href="/\spam2.example/b">2</a><a href="http:spam3.example">3</a><a href="https://spam4.example/">4</a>"#;
        let found = urls(html, ORIGIN);
        assert_eq!(found.len(), 4, "{found:?}");
        for host in ["spam.example", "spam2.example", "spam3.example", "spam4.example"] {
            assert!(found.iter().any(|u| u.contains(host)), "{host} missing: {found:?}");
        }
    }

    #[test]
    fn same_site_is_a_host_comparison_not_a_prefix() {
        let html = r#"<a href="https://example.org/x">own</a><a href="/y">own</a><a href="https://example.org.spam.example/">not own</a>"#;
        assert_eq!(urls(html, ORIGIN), vec!["https://example.org.spam.example/"]);
    }

    #[test]
    fn tags_mentions_fragments_and_other_schemes_are_skipped() {
        let html = r##"<a class="hashtag" href="https://r.example/tags/x">#x</a><a class="u-url mention" href="https://r.example/@a">@a</a><a href="#top">top</a><a href="">e</a><a href="mailto:a@b.example">m</a><a href="javascript:x">j</a>"##;
        assert!(urls(html, ORIGIN).is_empty());
    }

    #[test]
    fn urls_are_distinct_and_lose_their_fragment() {
        let html = r#"<a href="https://a.example/p#one">1</a><a href="https://a.example/p#two">2</a>"#;
        assert_eq!(urls(html, ORIGIN), vec!["https://a.example/p"]);
    }

    #[test]
    fn a_bad_origin_finds_nothing() {
        assert!(urls(r#"<a href="https://a.example/">a</a>"#, "not a url").is_empty());
    }

    // --- extract_first_url: the link preview ---

    #[test]
    fn first_url_keeps_an_absolute_link_as_written() {
        let html = r#"<a href="https://例え.jp/">jp</a><a href="https://b.example/">b</a>"#;
        assert_eq!(first_url(html, ORIGIN).as_deref(), Some("https://例え.jp/"));
    }

    #[test]
    fn first_url_resolves_a_protocol_relative_link() {
        let html = r#"<a href="//a.example/x">a</a>"#;
        assert_eq!(first_url(html, ORIGIN).as_deref(), Some("https://a.example/x"));
    }

    #[test]
    fn first_url_agrees_with_urls_about_what_is_external() {
        let html = r#"<a href="/own">own</a><a class="mention" href="https://r.example/@a">@a</a><a href="https://c.example/">c</a>"#;
        assert_eq!(first_url(html, ORIGIN).as_deref(), Some("https://c.example/"));
        assert_eq!(first_url(r#"<a href="/own">own</a>"#, ORIGIN), None);
    }

    // --- count_images ---

    #[test]
    fn images_are_counted() {
        assert_eq!(images(r#"<p><img src="a"><img src="b"></p>"#), 2);
        assert_eq!(images("<p>none</p>"), 0);
    }

    // --- parse_og_metadata ---

    #[test]
    fn og_tags_win_over_twitter_and_fallbacks() {
        let html = r#"<html><head><title>Plain</title>
            <meta property="og:title" content="OG title">
            <meta name="twitter:title" content="Twitter title">
            <meta property="og:description" content="OG desc">
            <meta property="og:image" content="https://i.example/a.png">
            <meta property="og:site_name" content="Site"></head></html>"#;
        let og = og_metadata(html);
        assert_eq!(og.title.as_deref(), Some("OG title"));
        assert_eq!(og.description.as_deref(), Some("OG desc"));
        assert_eq!(og.image_url.as_deref(), Some("https://i.example/a.png"));
        assert_eq!(og.site_name.as_deref(), Some("Site"));
    }

    #[test]
    fn og_falls_back_to_twitter_then_the_document() {
        let html = r#"<html><head><title> Plain title </title>
            <meta name="twitter:image" content="https://i.example/t.png">
            <meta name="description" content="Meta desc"></head></html>"#;
        let og = og_metadata(html);
        assert_eq!(og.title.as_deref(), Some("Plain title"));
        assert_eq!(og.description.as_deref(), Some("Meta desc"));
        assert_eq!(og.image_url.as_deref(), Some("https://i.example/t.png"));
        assert_eq!(og.site_name, None);
    }
}
