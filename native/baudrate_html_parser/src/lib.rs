use scraper::{Html, Selector};

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

/// Parse an HTML fragment and extract the first external URL from `<a href="...">` tags.
///
/// Filters out:
/// - Empty or fragment-only hrefs
/// - Links with class "hashtag" or "mention"
/// - Non-HTTP(S) URLs
/// - URLs starting with the given origin
#[rustler::nif]
fn extract_first_url(html: &str, origin: &str) -> Option<String> {
    let fragment = Html::parse_fragment(html);
    let selector = Selector::parse("a[href]").unwrap();

    for element in fragment.select(&selector) {
        let href = match element.value().attr("href") {
            Some(h) if !h.is_empty() => h,
            _ => continue,
        };

        if href.starts_with('#') {
            continue;
        }

        let classes = element.value().attr("class").unwrap_or("");
        if classes.contains("hashtag") || classes.contains("mention") {
            continue;
        }

        if !href.starts_with("http://") && !href.starts_with("https://") {
            continue;
        }

        if href.starts_with(origin) {
            continue;
        }

        return Some(href.to_string());
    }

    None
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
