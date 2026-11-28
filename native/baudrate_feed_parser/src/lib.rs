use feed_rs::model::Entry;
use feed_rs::parser::{Builder, Parser};

/// Normalized feed entry returned to Elixir.
///
/// All date/times are encoded as RFC 3339 strings so that Elixir can
/// parse them with `DateTime.from_iso8601/1`.
#[cfg_attr(not(test), derive(rustler::NifStruct))]
#[cfg_attr(not(test), module = "Baudrate.Bots.SyndicationFeedParserNative.Entry")]
struct NifEntry {
    /// Unique identifier (guid / entry id).  `None` means the entry has no
    /// usable id; the Elixir side falls back to the link.
    id: Option<String>,
    /// Raw title string (may contain HTML entities; strip_tags applied on
    /// the Elixir side via the existing Ammonia NIF).
    title: Option<String>,
    /// Primary link URL (alternate link preferred; falls back to first link).
    link: Option<String>,
    /// Full HTML body (content:encoded or first `<content>` block).
    /// `None` when neither content nor summary is present.
    content: Option<String>,
    /// Short summary / description.  Used as fallback when `content` is None.
    summary: Option<String>,
    /// Category terms / tags.
    tags: Vec<String>,
    /// Publication date as RFC 3339 string, or `None`.
    published_rfc3339: Option<String>,
}

/// Parse an RSS 2.0, Atom 1.0, RSS 1.0, or JSON feed.
///
/// Returns `{:ok, entries}` or `{:error, reason}`.
#[cfg(not(test))]
#[rustler::nif(schedule = "DirtyCpu")]
fn parse_feed(data: rustler::Binary) -> Result<Vec<NifEntry>, String> {
    parse(data.as_slice())
}

// The NIF is a one-line wrapper, so `cargo test` can exercise the parsing
// without a BEAM (Phase 8A).
// The NIF glue (`#[rustler::nif]`, `NifStruct`, `init!`) is `cfg(not(test))`:
// since rustler 0.39 it links the `enif_*` symbols the BEAM provides, which a
// test binary has no BEAM to supply.
fn parse(data: &[u8]) -> Result<Vec<NifEntry>, String> {
    let feed = parser().parse(data).map_err(|e| e.to_string())?;

    Ok(feed.entries.iter().map(nif_entry_from).collect())
}

fn parser() -> Parser {
    Builder::new()
        // feed-rs invents an id (a hash of link and title) for an entry that
        // has none. An invented id changes whenever the title is edited, so
        // the same post would be syndicated twice; an empty id instead makes
        // the Elixir side key the entry by its link, as it always has.
        .id_generator(|_links, _title, _uri| String::new())
        // Baudrate runs every title and body through Ammonia on the Elixir
        // side (`Baudrate.Bots.SyndicationFeedParser`), the single sanitizer
        // of record. The crate's own pass needs its `sanitize` feature, which
        // is off; the flag is cleared too so enabling it never sanitizes twice.
        .sanitize_content(false)
        .build()
}

fn nif_entry_from(entry: &Entry) -> NifEntry {
    let id = Some(entry.id.trim())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_owned());

    let title = entry.title.as_ref().map(|t| t.content.clone());

    let link = pick_link(entry);

    // Prefer content:encoded / full content over summary.
    let content = entry.content.as_ref().and_then(|c| c.body.clone());
    let summary = entry.summary.as_ref().map(|t| t.content.clone());

    let tags = collect_tags(entry);

    // `published` already covers `dc:date`; fall back to `updated`.
    // The instant is sent in UTC (`…Z`), which `DateTime.from_iso8601/1` reads.
    let published_rfc3339 = entry
        .published
        .as_ref()
        .or(entry.updated.as_ref())
        .map(|dt| dt.timestamp().to_string());

    NifEntry {
        id,
        title,
        link,
        content,
        summary,
        tags,
        published_rfc3339,
    }
}

fn pick_link(entry: &Entry) -> Option<String> {
    // Prefer rel="alternate", then the first link without a rel (an RSS
    // <link> or a JSON Feed `url`), then anything. Comment links
    // (`<comments>`, `wfw:commentRss`) carry a target and are skipped.
    let usable = || {
        entry
            .links
            .iter()
            .filter(|l| l.target.is_none() && !l.href.is_empty())
    };

    usable()
        .find(|l| l.rel.as_deref() == Some("alternate"))
        .or_else(|| usable().find(|l| l.rel.is_none()))
        .or_else(|| usable().next())
        .map(|l| l.href.clone())
}

fn collect_tags(entry: &Entry) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();

    entry
        .categories
        .iter()
        .map(|c| {
            // Prefer human-readable label; fall back to term.
            c.label
                .as_deref()
                .filter(|s| !s.is_empty())
                .unwrap_or(c.term.as_str())
                .to_owned()
        })
        .filter(|s| !s.is_empty())
        // Keep the first of each, in order (`Vec::dedup` would remove only
        // *adjacent* repeats).
        .filter(|s| seen.insert(s.clone()))
        .collect()
}

#[cfg(not(test))]
rustler::init!("Elixir.Baudrate.Bots.SyndicationFeedParserNative");

#[cfg(test)]
mod tests {
    use super::*;

    fn one(xml: &str) -> NifEntry {
        let mut entries = parse(xml.as_bytes()).expect("parses");
        assert_eq!(entries.len(), 1);
        entries.remove(0)
    }

    #[test]
    fn rss_item_fields() {
        let e = one(
            r#"<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>F</title>
            <item><guid>g-1</guid><title>Rust &amp; Ruby</title><link>https://f.example/1</link>
            <description>short</description><content:encoded><![CDATA[<p>full</p>]]></content:encoded>
            <category>a</category><category>b</category><category>a</category>
            <pubDate>Tue, 01 Sep 2026 10:00:00 +0000</pubDate></item></channel></rss>"#,
        );
        assert_eq!(e.id.as_deref(), Some("g-1"));
        assert_eq!(e.title.as_deref(), Some("Rust & Ruby"));
        assert_eq!(e.link.as_deref(), Some("https://f.example/1"));
        assert_eq!(e.content.as_deref(), Some("<p>full</p>"));
        assert_eq!(e.summary.as_deref(), Some("short"));
        // A repeated category is kept once, in first-seen order.
        assert_eq!(e.tags, vec!["a".to_string(), "b".to_string()]);
        assert!(e.published_rfc3339.as_deref().unwrap().starts_with("2026-09-01T10:00:00"));
    }

    // Baudrate's Ammonia pass is the one sanitizer of record; the crate's own
    // must stay off, or two allow-lists would disagree.
    #[test]
    fn html_reaches_elixir_unsanitized() {
        let e = one(
            r#"<rss version="2.0"><channel><title>F</title><item><guid>x</guid><title>t</title>
            <description><![CDATA[<p onclick="x()">raw</p><script>s()</script>]]></description></item></channel></rss>"#,
        );
        let summary = e.summary.unwrap();
        assert!(summary.contains("onclick"), "{summary}");
        assert!(summary.contains("<script>"), "{summary}");
    }

    #[test]
    fn atom_prefers_the_alternate_link() {
        let e = one(
            r#"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>F</title><id>f</id><updated>2026-09-01T00:00:00Z</updated>
            <entry><id>urn:e:1</id><title>T</title><updated>2026-09-02T00:00:00Z</updated>
            <link rel="edit" href="https://f.example/edit"/><link rel="alternate" href="https://f.example/post"/>
            <content type="html">&lt;p&gt;body&lt;/p&gt;</content></entry></feed>"#,
        );
        assert_eq!(e.id.as_deref(), Some("urn:e:1"));
        assert_eq!(e.link.as_deref(), Some("https://f.example/post"));
        assert_eq!(e.content.as_deref(), Some("<p>body</p>"));
        // No published date: the updated date is used.
        assert!(e.published_rfc3339.as_deref().unwrap().starts_with("2026-09-02"));
    }

    #[test]
    fn an_empty_id_is_none() {
        let e = one(
            r#"<rss version="2.0"><channel><title>F</title><item><guid></guid><title>t</title><link>https://f.example/2</link></item></channel></rss>"#,
        );
        assert_eq!(e.id, None);
        assert_eq!(e.link.as_deref(), Some("https://f.example/2"));
    }

    #[test]
    fn json_feed_items() {
        let e = one(
            r#"{"version":"https://jsonfeed.org/version/1.1","title":"F","items":[{"id":"j1","url":"https://f.example/j","content_html":"<p>j</p>","tags":["x"]}]}"#,
        );
        assert_eq!(e.id.as_deref(), Some("j1"));
        assert_eq!(e.link.as_deref(), Some("https://f.example/j"));
        assert_eq!(e.content.as_deref(), Some("<p>j</p>"));
        assert_eq!(e.tags, vec!["x".to_string()]);
    }

    #[test]
    fn something_that_is_not_a_feed_is_an_error() {
        assert!(parse(b"<html><body>not a feed</body></html>").is_err());
        assert!(parse(b"this is not xml").is_err());
    }

    #[test]
    fn an_rss_comments_link_is_not_the_entry_link() {
        let e = one(
            r#"<rss version="2.0"><channel><title>F</title><item><guid>c</guid><title>t</title>
            <comments>https://f.example/c#comments</comments><link>https://f.example/c</link></item></channel></rss>"#,
        );
        assert_eq!(e.link.as_deref(), Some("https://f.example/c"));
    }

    #[test]
    fn rss1_items_with_dc_date() {
        let e = one(
            r#"<?xml version="1.0"?><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
            <channel rdf:about="https://f.example/"><title>F</title><link>https://f.example/</link></channel>
            <item rdf:about="https://f.example/r1"><title>R</title><link>https://f.example/r1</link><description>d</description>
            <dc:date>2026-09-03T08:00:00+09:00</dc:date></item></rdf:RDF>"#,
        );
        assert_eq!(e.link.as_deref(), Some("https://f.example/r1"));
        assert_eq!(e.summary.as_deref(), Some("d"));
        // Sent as the same instant in UTC.
        assert_eq!(e.published_rfc3339.as_deref(), Some("2026-09-02T23:00:00Z"));
    }

    // A NIF that overflows its stack takes the whole BEAM down, so deep
    // nesting from a hostile feed must not recurse.
    #[test]
    fn deeply_nested_markup_does_not_overflow_the_stack() {
        let depth = 200_000;
        let xml = format!(
            r#"<rss version="2.0"><channel><title>F</title><item><guid>d</guid><title>t</title><description>{}{}</description>{}{}</item></channel></rss>"#,
            "<x>".repeat(depth),
            "</x>".repeat(depth),
            "<y>".repeat(depth),
            "</y>".repeat(depth),
        );
        // Run on a small stack, like a dirty scheduler's.
        let handle = std::thread::Builder::new()
            .stack_size(256 * 1024)
            .spawn(move || parse(xml.as_bytes()).map(|e| e.len()))
            .unwrap();
        let _ = handle.join().expect("no stack overflow");
    }
}
