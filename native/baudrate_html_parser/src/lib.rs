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

/// Parse an HTML document and extract Open Graph / Twitter Card / fallback metadata.
#[rustler::nif]
fn parse_og_metadata(html: &str) -> OgMetadata {
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
