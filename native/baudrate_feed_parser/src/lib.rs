use feedparser_rs::{parse, Entry};

/// Normalized feed entry returned to Elixir.
///
/// All date/times are encoded as RFC 3339 strings so that Elixir can
/// parse them with `DateTime.from_iso8601/1`.
#[derive(rustler::NifStruct)]
#[module = "Baudrate.Bots.FeedParserNative.Entry"]
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
    let feed = parse(data.as_slice()).map_err(|e| e.to_string())?;

    let entries = feed
        .entries
        .iter()
        .map(nif_entry_from)
        .collect();

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

    tags.dedup();
    tags
}

rustler::init!("Elixir.Baudrate.Bots.FeedParserNative");
