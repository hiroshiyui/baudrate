use feedparser_rs::{parse_with_options, Entry, ParseOptions};

/// Normalized feed entry returned to Elixir.
///
/// All date/times are encoded as RFC 3339 strings so that Elixir can
/// parse them with `DateTime.from_iso8601/1`.
#[derive(rustler::NifStruct)]
#[module = "Baudrate.Bots.SyndicationFeedParserNative.Entry"]
struct NifEntry {
    /// Unique identifier (guid / entry id).  `None` means the entry has no
    /// usable id and should be skipped on the Elixir side.
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
#[rustler::nif(schedule = "DirtyCpu")]
fn parse_feed(data: rustler::Binary) -> Result<Vec<NifEntry>, String> {
    parse(data.as_slice())
}

// The NIF is a one-line wrapper, so `cargo test` can exercise the parsing
// without a BEAM (Phase 8A).
fn parse(data: &[u8]) -> Result<Vec<NifEntry>, String> {
    // feedparser-rs >= 0.6 sanitizes HTML-bearing fields itself by default.
    // Baudrate runs every title and body through Ammonia on the Elixir side
    // (`Baudrate.Bots.FeedParser`), which is the single sanitizer of record, so
    // the crate-side pass is disabled: two allowlists would disagree, and its
    // entity escaping would double-encode plain-text titles. Relative-URI
    // resolution and the default parser limits are kept.
    let options = ParseOptions {
        sanitize_html: false,
        ..ParseOptions::default()
    };

    let feed = parse_with_options(data, &options).map_err(|e| e.to_string())?;

    let entries = feed.entries.iter().map(nif_entry_from).collect();

    Ok(entries)
}

fn nif_entry_from(entry: &Entry) -> NifEntry {
    let id = entry
        .id
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_owned());

    let title = entry.title.as_deref().map(|s| s.to_owned());

    let link = pick_link(entry);

    // Prefer content:encoded / full content over summary.
    let content = entry.content.first().map(|c| c.value.clone());
    let summary = entry.summary.as_deref().map(|s| s.to_owned());

    let tags = collect_tags(entry);

    // Prefer published, fall back to dc_date, then updated.
    let published_rfc3339 = entry
        .published
        .or(entry.dc_date)
        .or(entry.updated)
        .map(|dt| dt.to_rfc3339());

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
    // 1. Try explicit primary link field.
    if let Some(l) = &entry.link {
        if !l.is_empty() {
            return Some(l.clone());
        }
    }

    // 2. Walk `links` array: prefer rel="alternate", then no rel, then anything.
    let mut fallback: Option<String> = None;

    for link in &entry.links {
        let href = link.href.as_str();
        if href.is_empty() {
            continue;
        }
        match link.rel.as_deref() {
            Some("alternate") => return Some(href.to_owned()),
            None => {
                if fallback.is_none() {
                    fallback = Some(href.to_owned());
                }
            }
            _ => {
                if fallback.is_none() {
                    fallback = Some(href.to_owned());
                }
            }
        }
    }

    fallback
}

fn collect_tags(entry: &Entry) -> Vec<String> {
    let mut tags: Vec<String> = entry
        .tags
        .iter()
        .map(|t| {
            // Prefer human-readable label; fall back to term.
            t.label
                .as_deref()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| t.term.as_str())
                .to_owned()
        })
        .filter(|s| !s.is_empty())
        .collect();

    // Also include dc:subject entries as tags.
    for subject in &entry.dc_subject {
        if !subject.is_empty() && !tags.contains(subject) {
            tags.push(subject.clone());
        }
    }

    // `Vec::dedup` removes only *adjacent* repeats, so `a, b, a` kept both
    // `a`s; keep the first of each, in order.
    let mut seen = std::collections::HashSet::new();
    tags.retain(|t| seen.insert(t.clone()));
    tags
}

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
    fn something_that_is_not_a_feed_has_no_entries() {
        let entries = parse(b"<html><body>not a feed</body></html>").unwrap_or_default();
        assert!(entries.is_empty());
    }
}
