use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

use pith_core::parser::{self, RefTarget, Span};
use pith_core::{Id, Op, Origin, Store, TxMeta, order};
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use uuid::Uuid;

use crate::transit::{self, Value};
use crate::{Error, Result};

const SUPPORTED_SCHEMA_MAJOR: i64 = 65;
const DEFAULT_CHUNK_SIZE: usize = 500;
const MAX_SAMPLES_PER_KIND: usize = 10;

#[derive(Debug, Clone)]
pub struct ImportOptions {
    pub dry_run: bool,
    pub actor: String,
    pub chunk_size: usize,
}

impl Default for ImportOptions {
    fn default() -> Self {
        Self {
            dry_run: false,
            actor: "import".to_string(),
            chunk_size: DEFAULT_CHUNK_SIZE,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct SkippedCounts {
    pub built_in_or_hidden: usize,
    pub recycled_or_deleted: usize,
    pub views: usize,
    pub assets: usize,
    pub whiteboards: usize,
    pub properties: usize,
    pub history: usize,
    pub files: usize,
    pub kv: usize,
    pub other: usize,
}

impl SkippedCounts {
    pub fn total(&self) -> usize {
        self.built_in_or_hidden
            + self.recycled_or_deleted
            + self.views
            + self.assets
            + self.whiteboards
            + self.properties
            + self.history
            + self.files
            + self.kv
            + self.other
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UnresolvedRef {
    pub source_block: String,
    pub kind: String,
    pub target: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DowngradeSample {
    pub kind: String,
    pub count: usize,
    pub samples: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ImportReport {
    pub schema_major: i64,
    pub schema_minor: i64,
    pub dry_run: bool,
    pub pages_imported: usize,
    pub journals_imported: usize,
    pub blocks_imported: usize,
    pub collapsed_applied: usize,
    pub favorites_applied: usize,
    pub pages_already_present: usize,
    pub blocks_already_present: usize,
    pub txns_written: usize,
    pub skipped: SkippedCounts,
    pub unresolved_refs: Vec<UnresolvedRef>,
    pub downgraded: Vec<DowngradeSample>,
}

struct Datom {
    e: i64,
    a: String,
    v: Value,
    tx: i64,
}

type EntityMap = HashMap<i64, HashMap<String, Vec<Value>>>;

struct DowngradeTracker {
    counts: BTreeMap<String, (usize, Vec<String>)>,
}

impl DowngradeTracker {
    fn new() -> Self {
        Self {
            counts: BTreeMap::new(),
        }
    }

    fn record(&mut self, kind: &str, sample: impl Into<String>) {
        let entry = self
            .counts
            .entry(kind.to_string())
            .or_insert_with(|| (0, Vec::new()));
        entry.0 += 1;
        if entry.1.len() < MAX_SAMPLES_PER_KIND {
            entry.1.push(sample.into());
        }
    }

    fn into_vec(self) -> Vec<DowngradeSample> {
        self.counts
            .into_iter()
            .map(|(kind, (count, samples))| DowngradeSample {
                kind,
                count,
                samples,
            })
            .collect()
    }
}

struct PlannedPage {
    eid: i64,
    id: Id,
    title: String,
    title_lower: String,
    journal_day: Option<i32>,
    favorite: bool,
}

struct PlannedBlock {
    id: Id,
    page_id: Id,
    parent_id: Option<Id>,
    order_key: String,
    content: String,
    collapsed: bool,
}

struct ImportPlan {
    pages: Vec<PlannedPage>,
    blocks: Vec<PlannedBlock>,
    report: ImportReport,
}

pub fn import_logseq_db(
    source_path: &Path,
    store: &mut Store,
    options: &ImportOptions,
) -> Result<ImportReport> {
    import_logseq_db_with_progress(source_path, store, options, |_, _| true)
}

pub fn import_logseq_db_with_progress<F>(
    source_path: &Path,
    store: &mut Store,
    options: &ImportOptions,
    mut on_progress: F,
) -> Result<ImportReport>
where
    F: FnMut(usize, usize) -> bool,
{
    let entities = read_entities(source_path)?;
    let mut plan = build_plan(&entities, options.dry_run)?;

    if options.dry_run {
        plan.report.pages_imported = plan
            .pages
            .iter()
            .filter(|p| p.journal_day.is_none())
            .count();
        plan.report.journals_imported = plan
            .pages
            .iter()
            .filter(|p| p.journal_day.is_some())
            .count();
        plan.report.blocks_imported = plan.blocks.len();
        plan.report.collapsed_applied = plan.blocks.iter().filter(|b| b.collapsed).count();
        plan.report.favorites_applied = plan.pages.iter().filter(|p| p.favorite).count();
        return Ok(plan.report);
    }

    apply_plan(store, &mut plan, options, &mut on_progress)?;
    Ok(plan.report)
}

fn read_entities(source_path: &Path) -> Result<EntityMap> {
    let conn = Connection::open_with_flags(
        source_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;

    let root_content: String = conn
        .query_row("SELECT content FROM kvs WHERE addr = 0", [], |row| {
            row.get(0)
        })
        .map_err(|e| Error::InvalidLogseqDb(format!("missing root row addr=0: {e}")))?;

    let root_meta = transit::decode(&root_content)?;
    let eavt_root = root_meta
        .map_get_keyword("eavt")
        .and_then(Value::as_i64)
        .ok_or_else(|| Error::InvalidLogseqDb("root metadata missing :eavt".into()))?;

    let mut stmt = conn.prepare("SELECT content, addresses FROM kvs WHERE addr = ?1")?;
    let mut stack = vec![eavt_root];
    let mut datoms: Vec<Datom> = Vec::new();
    let mut visited = HashSet::new();

    while let Some(addr) = stack.pop() {
        if !visited.insert(addr) {
            return Err(Error::InvalidLogseqDb(format!(
                "cycle detected in kvs tree at addr {addr}"
            )));
        }
        let (content, addresses): (String, Option<String>) = stmt
            .query_row([addr], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| Error::InvalidLogseqDb(format!("missing kvs node addr={addr}: {e}")))?;

        if let Some(addrs_json) = addresses {
            let children: Vec<i64> = serde_json::from_str(&addrs_json)?;
            for child in children.into_iter().rev() {
                stack.push(child);
            }
        } else {
            let decoded = transit::decode(&content)?;
            let keys = decoded
                .map_get_keyword("keys")
                .and_then(Value::as_list)
                .ok_or_else(|| {
                    Error::InvalidLogseqDb(format!("leaf node addr={addr} missing :keys"))
                })?;
            for item in keys {
                datoms.push(parse_datom(item)?);
            }
        }
    }

    let tail_opt: Option<String> =
        match conn.query_row("SELECT content FROM kvs WHERE addr = 1", [], |row| {
            row.get(0)
        }) {
            Ok(s) => Some(s),
            Err(rusqlite::Error::QueryReturnedNoRows) => None,
            Err(e) => return Err(Error::Sqlite(e)),
        };

    if let Some(tail_str) = tail_opt {
        let mut active: HashMap<(i64, String, String), Datom> =
            HashMap::with_capacity(datoms.len());
        for d in datoms {
            let key = (d.e, d.a.clone(), value_dedup_key(&d.v));
            active.insert(key, d);
        }
        let tail_val = transit::decode(&tail_str)?;
        if let Some(batches) = tail_val.as_list() {
            for batch in batches {
                if let Some(items) = batch.as_list() {
                    for item in items {
                        let d = parse_datom(item)?;
                        let key = (d.e, d.a.clone(), value_dedup_key(&d.v));
                        if d.tx < 0 {
                            active.remove(&key);
                        } else {
                            active.insert(key, d);
                        }
                    }
                }
            }
        }
        datoms = active.into_values().collect();
    }

    let mut entities: EntityMap = HashMap::new();
    for d in datoms {
        entities
            .entry(d.e)
            .or_default()
            .entry(d.a)
            .or_default()
            .push(d.v);
    }
    Ok(entities)
}

fn parse_datom(val: &Value) -> Result<Datom> {
    let list = val
        .as_list()
        .ok_or_else(|| Error::InvalidLogseqDb("datom is not a list".into()))?;
    if list.len() < 4 {
        return Err(Error::InvalidLogseqDb(format!(
            "datom has {} elements, expected 4",
            list.len()
        )));
    }
    let e = list[0]
        .as_i64()
        .ok_or_else(|| Error::InvalidLogseqDb("datom entity id is not an integer".into()))?;
    let a = list[1]
        .as_keyword()
        .ok_or_else(|| Error::InvalidLogseqDb("datom attribute is not a keyword".into()))?
        .to_string();
    let v = list[2].clone();
    let tx = list[3]
        .as_i64()
        .ok_or_else(|| Error::InvalidLogseqDb("datom tx is not an integer".into()))?;
    Ok(Datom { e, a, v, tx })
}

fn value_dedup_key(v: &Value) -> String {
    match v {
        Value::Null => "null".into(),
        Value::Bool(b) => format!("b:{b}"),
        Value::Int(i) => format!("i:{i}"),
        Value::Float(f) => format!("f:{:.12}", f),
        Value::String(s) => format!("s:{s}"),
        Value::Keyword(k) => format!("k:{k}"),
        Value::Symbol(s) => format!("y:{s}"),
        Value::Uuid(u) => format!("u:{u}"),
        Value::Instant(m) => format!("m:{m}"),
        Value::List(items) => {
            let inner: Vec<String> = items.iter().map(value_dedup_key).collect();
            format!("[{}]", inner.join(","))
        }
        Value::Map(entries) => {
            let mut pairs: Vec<String> = entries
                .iter()
                .map(|(k, v)| format!("{}=>{}", value_dedup_key(k), value_dedup_key(v)))
                .collect();
            pairs.sort();
            format!("{{{}}}", pairs.join(","))
        }
        Value::Tagged(t, inner) => format!("#{t}:{}", value_dedup_key(inner)),
    }
}

fn first_str<'a>(attrs: &'a HashMap<String, Vec<Value>>, key: &str) -> Option<&'a str> {
    attrs
        .get(key)
        .and_then(|vs| vs.first())
        .and_then(Value::as_str)
}

fn first_keyword<'a>(attrs: &'a HashMap<String, Vec<Value>>, key: &str) -> Option<&'a str> {
    attrs
        .get(key)
        .and_then(|vs| vs.first())
        .and_then(Value::as_keyword)
}

fn first_i64(attrs: &HashMap<String, Vec<Value>>, key: &str) -> Option<i64> {
    attrs
        .get(key)
        .and_then(|vs| vs.first())
        .and_then(Value::as_i64)
}

fn first_bool(attrs: &HashMap<String, Vec<Value>>, key: &str) -> Option<bool> {
    attrs
        .get(key)
        .and_then(|vs| vs.first())
        .and_then(Value::as_bool)
}

fn first_uuid(attrs: &HashMap<String, Vec<Value>>, key: &str) -> Option<Uuid> {
    attrs
        .get(key)
        .and_then(|vs| vs.first())
        .and_then(Value::as_uuid)
}

fn tag_eids(attrs: &HashMap<String, Vec<Value>>) -> Vec<i64> {
    attrs
        .get("block/tags")
        .map(|vs| vs.iter().filter_map(Value::as_i64).collect())
        .unwrap_or_default()
}

fn validate_schema_version(
    entities: &EntityMap,
    ident_to_eid: &HashMap<String, i64>,
) -> Result<(i64, i64)> {
    let eid = ident_to_eid
        .get("logseq.kv/schema-version")
        .ok_or(Error::MissingSchemaVersion)?;
    let attrs = entities.get(eid).ok_or(Error::MissingSchemaVersion)?;
    let val = attrs
        .get("kv/value")
        .and_then(|vs| vs.first())
        .ok_or(Error::MissingSchemaVersion)?;
    let major = val
        .map_get_keyword("major")
        .and_then(Value::as_i64)
        .ok_or(Error::MissingSchemaVersion)?;
    let minor = val
        .map_get_keyword("minor")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if major != SUPPORTED_SCHEMA_MAJOR {
        return Err(Error::UnsupportedSchemaVersion { major, minor });
    }
    Ok((major, minor))
}

fn format_journal_title(day: i32) -> Option<String> {
    let year = day / 10_000;
    let month = (day / 100) % 100;
    let dom = day % 100;
    if !(1..=12).contains(&month) || !(1..=31).contains(&dom) {
        return None;
    }
    Some(format!("{year:04}-{month:02}-{dom:02}"))
}

fn build_plan(entities: &EntityMap, dry_run: bool) -> Result<ImportPlan> {
    let mut eid_to_ident: HashMap<i64, String> = HashMap::new();
    let mut ident_to_eid: HashMap<String, i64> = HashMap::new();
    for (&eid, attrs) in entities {
        if let Some(ident) = first_keyword(attrs, "db/ident") {
            eid_to_ident.insert(eid, ident.to_string());
            ident_to_eid.insert(ident.to_string(), eid);
        }
    }

    let (schema_major, schema_minor) = validate_schema_version(entities, &ident_to_eid)?;

    let class_journal = ident_to_eid.get("logseq.class/Journal").copied();
    let class_page = ident_to_eid.get("logseq.class/Page").copied();
    let class_tag = ident_to_eid.get("logseq.class/Tag").copied();
    let class_property = ident_to_eid.get("logseq.class/Property").copied();
    let class_asset = ident_to_eid.get("logseq.class/Asset").copied();
    let class_whiteboard = ident_to_eid.get("logseq.class/Whiteboard").copied();
    let class_code = ident_to_eid.get("logseq.class/Code-block").copied();
    let class_quote = ident_to_eid.get("logseq.class/Quote-block").copied();

    let mut recycle_page_eids: HashSet<i64> = HashSet::new();
    let mut favorites_page_eids: HashSet<i64> = HashSet::new();
    for (&eid, attrs) in entities {
        if first_bool(attrs, "logseq.property/built-in?") == Some(true)
            && let Some(title) = first_str(attrs, "block/title")
        {
            if title == "Recycle" {
                recycle_page_eids.insert(eid);
            } else if title == "$$$favorites" {
                favorites_page_eids.insert(eid);
            }
        }
    }

    let mut favorite_target_eids: HashSet<i64> = HashSet::new();
    for attrs in entities.values() {
        if let Some(page_eid) = first_i64(attrs, "block/page")
            && favorites_page_eids.contains(&page_eid)
            && let Some(link_eid) = first_i64(attrs, "block/link")
        {
            favorite_target_eids.insert(link_eid);
        }
    }

    let mut prop_defs: HashMap<String, (String, bool)> = HashMap::new();
    for attrs in entities.values() {
        if let Some(ident) = first_keyword(attrs, "db/ident")
            && (ident.starts_with("user.property/") || ident.starts_with("plugin.property."))
        {
            let label = first_str(attrs, "block/title")
                .filter(|s| !s.trim().is_empty())
                .unwrap_or(ident)
                .to_string();
            let is_ref = first_keyword(attrs, "db/valueType") == Some("db.type/ref");
            prop_defs.insert(ident.to_string(), (normalize_prop_key(&label), is_ref));
        }
    }

    let mut skipped = SkippedCounts::default();
    let mut downgraded = DowngradeTracker::new();
    let mut raw_pages: Vec<(i64, Id, String, Option<i32>, bool, bool)> = Vec::new();
    let mut skipped_page_eids: HashSet<i64> = HashSet::new();
    let mut uuid_to_title_all: HashMap<Uuid, String> = HashMap::new();

    for attrs in entities.values() {
        if let Some(u) = first_uuid(attrs, "block/uuid")
            && let Some(t) = first_str(attrs, "block/title")
        {
            uuid_to_title_all.insert(u, t.to_string());
        }
    }

    let mut all_eids: Vec<i64> = entities.keys().copied().collect();
    all_eids.sort_unstable();

    for &eid in &all_eids {
        let attrs = &entities[&eid];
        if attrs.contains_key("block/page") {
            continue;
        }
        if attrs.contains_key("kv/value") {
            skipped.kv += 1;
            skipped_page_eids.insert(eid);
            continue;
        }
        if attrs.contains_key("logseq.property.history/block") {
            skipped.history += 1;
            skipped_page_eids.insert(eid);
            continue;
        }
        if attrs.contains_key("file/path") {
            skipped.files += 1;
            skipped_page_eids.insert(eid);
            continue;
        }
        if attrs.contains_key("logseq.property/view-for") {
            skipped.views += 1;
            skipped_page_eids.insert(eid);
            continue;
        }
        let tags = tag_eids(attrs);
        if first_bool(attrs, "block/deleted?") == Some(true) || recycle_page_eids.contains(&eid) {
            skipped.recycled_or_deleted += 1;
            skipped_page_eids.insert(eid);
            continue;
        }
        if class_asset.is_some_and(|c| tags.contains(&c)) {
            skipped.assets += 1;
            skipped_page_eids.insert(eid);
            continue;
        }
        if class_whiteboard.is_some_and(|c| tags.contains(&c)) {
            skipped.whiteboards += 1;
            skipped_page_eids.insert(eid);
            continue;
        }
        if class_property.is_some_and(|c| tags.contains(&c)) {
            skipped.properties += 1;
            skipped_page_eids.insert(eid);
            continue;
        }
        if first_bool(attrs, "logseq.property/built-in?") == Some(true)
            || first_bool(attrs, "logseq.property/hide?") == Some(true)
        {
            skipped.built_in_or_hidden += 1;
            skipped_page_eids.insert(eid);
            continue;
        }

        let is_journal = attrs.contains_key("block/journal-day")
            || class_journal.is_some_and(|c| tags.contains(&c));
        let is_page = class_page.is_some_and(|c| tags.contains(&c));
        let is_user_tag = class_tag.is_some_and(|c| tags.contains(&c));

        if !is_journal && !is_page && !is_user_tag {
            skipped.other += 1;
            skipped_page_eids.insert(eid);
            continue;
        }

        let Some(uuid) = first_uuid(attrs, "block/uuid") else {
            skipped.other += 1;
            skipped_page_eids.insert(eid);
            continue;
        };
        let id = Id::from_uuid(uuid);

        let (journal_day, title) = if is_journal {
            let day = first_i64(attrs, "block/journal-day").and_then(|d| i32::try_from(d).ok());
            match day.and_then(|d| format_journal_title(d).map(|t| (d, t))) {
                Some((d, t)) => (Some(d), t),
                None => {
                    let raw_title = first_str(attrs, "block/title")
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    let fallback = if raw_title.is_empty() {
                        format!("Untitled ({})", id.short_suffix(6))
                    } else {
                        raw_title
                    };
                    downgraded.record("invalid_journal_day", format!("eid={eid} title={fallback}"));
                    (None, fallback)
                }
            }
        } else {
            let raw_title = first_str(attrs, "block/title")
                .unwrap_or("")
                .trim()
                .to_string();
            let title = if raw_title.is_empty() {
                let fallback = format!("Untitled ({})", id.short_suffix(6));
                downgraded.record("empty_page_title", format!("eid={eid} -> {fallback}"));
                fallback
            } else {
                raw_title
            };
            (None, title)
        };

        let favorite = favorite_target_eids.contains(&eid);
        raw_pages.push((eid, id, title, journal_day, is_page, favorite));
    }

    raw_pages.sort_by(|a, b| {
        b.3.is_some()
            .cmp(&a.3.is_some())
            .then_with(|| b.4.cmp(&a.4))
            .then_with(|| a.0.cmp(&b.0))
    });

    let mut used_titles: HashSet<String> = HashSet::new();
    let mut used_journal_days: HashSet<i32> = HashSet::new();
    let mut pages: Vec<PlannedPage> = Vec::with_capacity(raw_pages.len());
    let mut page_eid_to_id: HashMap<i64, Id> = HashMap::new();
    let mut kept_page_ids: HashSet<Id> = HashSet::new();

    for (eid, id, mut title, mut journal_day, _, favorite) in raw_pages {
        if let Some(day) = journal_day
            && !used_journal_days.insert(day)
        {
            downgraded.record("duplicate_journal_day", format!("day={day} eid={eid}"));
            journal_day = None;
        }
        let mut lower = title.to_lowercase();
        if !used_titles.insert(lower.clone()) {
            let original = title.clone();
            let mut suffix = 2usize;
            loop {
                let candidate = format!("{original} ({suffix})");
                let candidate_lower = candidate.to_lowercase();
                if used_titles.insert(candidate_lower.clone()) {
                    title = candidate;
                    lower = candidate_lower;
                    break;
                }
                suffix += 1;
            }
            downgraded.record(
                "duplicate_page_title",
                format!("{original:?} -> {title:?} (id={id})"),
            );
        }
        page_eid_to_id.insert(eid, id);
        kept_page_ids.insert(id);
        pages.push(PlannedPage {
            eid,
            id,
            title,
            title_lower: lower,
            journal_day,
            favorite,
        });
    }

    let mut block_eids: Vec<i64> = Vec::new();
    let mut block_eid_to_id: HashMap<i64, Id> = HashMap::new();
    let mut kept_block_ids: HashSet<Id> = HashSet::new();

    for &eid in &all_eids {
        let attrs = &entities[&eid];
        let Some(page_eid) = first_i64(attrs, "block/page") else {
            continue;
        };

        if attrs.contains_key("logseq.property/view-for") {
            skipped.views += 1;
            continue;
        }
        if attrs.contains_key("logseq.property/created-from-property") {
            skipped.properties += 1;
            continue;
        }
        if first_bool(attrs, "block/deleted?") == Some(true)
            || recycle_page_eids.contains(&page_eid)
        {
            skipped.recycled_or_deleted += 1;
            continue;
        }
        let tags = tag_eids(attrs);
        if class_asset.is_some_and(|c| tags.contains(&c)) {
            skipped.assets += 1;
            continue;
        }
        if class_whiteboard.is_some_and(|c| tags.contains(&c)) {
            skipped.whiteboards += 1;
            continue;
        }
        if first_bool(attrs, "logseq.property/built-in?") == Some(true)
            || first_bool(attrs, "logseq.property/hide?") == Some(true)
        {
            skipped.built_in_or_hidden += 1;
            continue;
        }
        if !page_eid_to_id.contains_key(&page_eid) {
            if skipped_page_eids.contains(&page_eid) {
                skipped.built_in_or_hidden += 1;
            } else {
                skipped.other += 1;
            }
            continue;
        }
        let Some(uuid) = first_uuid(attrs, "block/uuid") else {
            skipped.other += 1;
            continue;
        };
        let id = Id::from_uuid(uuid);
        block_eids.push(eid);
        block_eid_to_id.insert(eid, id);
        kept_block_ids.insert(id);
    }

    let mut raw_parent: HashMap<i64, Option<i64>> = HashMap::with_capacity(block_eids.len());
    for &eid in &block_eids {
        let attrs = &entities[&eid];
        let page_eid = first_i64(attrs, "block/page").expect("block has page");
        let parent_eid = first_i64(attrs, "block/parent");
        let resolved = match parent_eid {
            None => None,
            Some(p) if p == page_eid => None,
            Some(p) if block_eid_to_id.contains_key(&p) => {
                let p_page = entities.get(&p).and_then(|pa| first_i64(pa, "block/page"));
                if p_page == Some(page_eid) {
                    Some(p)
                } else {
                    downgraded.record(
                        "cross_page_parent_reattached",
                        format!("block eid={eid} parent={p} reattached to page {page_eid}"),
                    );
                    None
                }
            }
            Some(p) => {
                downgraded.record(
                    "missing_parent_reattached",
                    format!("block eid={eid} parent={p} reattached to page {page_eid}"),
                );
                None
            }
        };
        raw_parent.insert(eid, resolved);
    }

    break_parent_cycles(&block_eids, &mut raw_parent, &mut downgraded);

    let mut children_by_parent: HashMap<(i64, Option<i64>), Vec<i64>> = HashMap::new();
    for &eid in &block_eids {
        let page_eid = first_i64(&entities[&eid], "block/page").expect("block has page");
        let parent_eid = raw_parent[&eid];
        children_by_parent
            .entry((page_eid, parent_eid))
            .or_default()
            .push(eid);
    }

    for siblings in children_by_parent.values_mut() {
        siblings.sort_by(|&a, &b| {
            let oa = first_str(&entities[&a], "block/order").unwrap_or("");
            let ob = first_str(&entities[&b], "block/order").unwrap_or("");
            oa.cmp(ob)
                .then_with(|| block_eid_to_id[&a].cmp(&block_eid_to_id[&b]))
        });
    }

    let mut unresolved_refs: Vec<UnresolvedRef> = Vec::new();
    let mut blocks: Vec<PlannedBlock> = Vec::with_capacity(block_eids.len());

    let mut ordered_pages: Vec<(i64, Id)> = pages.iter().map(|p| (p.eid, p.id)).collect();
    ordered_pages.sort_by_key(|&(eid, _)| eid);

    for (page_eid, page_id) in ordered_pages {
        let mut stack: Vec<(Option<i64>, Option<Id>)> = vec![(None, None)];
        while let Some((parent_eid, parent_id)) = stack.pop() {
            let Some(siblings) = children_by_parent.get(&(page_eid, parent_eid)) else {
                continue;
            };
            let mut prev_key: Option<String> = None;
            let mut next_parents: Vec<(Option<i64>, Option<Id>)> = Vec::new();
            for &eid in siblings {
                let order_key = order::between(prev_key.as_deref(), None)?;
                prev_key = Some(order_key.clone());

                let id = block_eid_to_id[&eid];
                let attrs = &entities[&eid];
                let content = build_block_content(
                    id,
                    attrs,
                    entities,
                    &eid_to_ident,
                    &page_eid_to_id,
                    &block_eid_to_id,
                    &kept_page_ids,
                    &kept_block_ids,
                    &uuid_to_title_all,
                    &prop_defs,
                    class_code,
                    class_quote,
                    &mut unresolved_refs,
                    &mut downgraded,
                );
                let collapsed = first_bool(attrs, "block/collapsed?").unwrap_or(false);
                blocks.push(PlannedBlock {
                    id,
                    page_id,
                    parent_id,
                    order_key,
                    content,
                    collapsed,
                });
                next_parents.push((Some(eid), Some(id)));
            }
            for item in next_parents.into_iter().rev() {
                stack.push(item);
            }
        }
    }

    let report = ImportReport {
        schema_major,
        schema_minor,
        dry_run,
        skipped,
        unresolved_refs,
        downgraded: downgraded.into_vec(),
        ..ImportReport::default()
    };

    Ok(ImportPlan {
        pages,
        blocks,
        report,
    })
}

fn break_parent_cycles(
    block_eids: &[i64],
    raw_parent: &mut HashMap<i64, Option<i64>>,
    downgraded: &mut DowngradeTracker,
) {
    for &start in block_eids {
        let mut seen = HashSet::new();
        let mut cur = Some(start);
        while let Some(node) = cur {
            if !seen.insert(node) {
                raw_parent.insert(start, None);
                downgraded.record("parent_cycle_broken", format!("block eid={start}"));
                break;
            }
            cur = raw_parent.get(&node).copied().flatten();
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn build_block_content(
    block_id: Id,
    attrs: &HashMap<String, Vec<Value>>,
    entities: &EntityMap,
    eid_to_ident: &HashMap<i64, String>,
    page_eid_to_id: &HashMap<i64, Id>,
    block_eid_to_id: &HashMap<i64, Id>,
    kept_page_ids: &HashSet<Id>,
    kept_block_ids: &HashSet<Id>,
    uuid_to_title_all: &HashMap<Uuid, String>,
    prop_defs: &HashMap<String, (String, bool)>,
    class_code: Option<i64>,
    class_quote: Option<i64>,
    unresolved_refs: &mut Vec<UnresolvedRef>,
    downgraded: &mut DowngradeTracker,
) -> String {
    let raw_title = first_str(attrs, "block/title").unwrap_or("");
    let mut content = rewrite_refs(
        block_id,
        raw_title,
        kept_page_ids,
        kept_block_ids,
        uuid_to_title_all,
        unresolved_refs,
    );

    let tags = tag_eids(attrs);
    let is_code_block = class_code.is_some_and(|c| tags.contains(&c))
        || first_keyword(attrs, "logseq.property.node/display-type") == Some("code");
    let is_quote_block = class_quote.is_some_and(|c| tags.contains(&c))
        || first_keyword(attrs, "logseq.property.node/display-type") == Some("quote");

    if is_code_block && !content.trim_start().starts_with("```") {
        let lang = first_str(attrs, "logseq.property.code/lang")
            .unwrap_or("")
            .trim();
        content = format!("```{lang}\n{content}\n```");
    } else if is_quote_block && !content.trim_start().starts_with("> ") {
        let quoted: Vec<String> = content.lines().map(|l| format!("> {l}")).collect();
        content = if quoted.is_empty() {
            "> ".to_string()
        } else {
            quoted.join("\n")
        };
    }

    if let Some(level) = first_i64(attrs, "logseq.property/heading")
        && (1..=6).contains(&level)
    {
        let hashes = "#".repeat(level as usize);
        let trimmed = content.trim_start();
        if !trimmed.starts_with('#') {
            content = format!("{hashes} {content}");
        }
    }

    let mut extra_props: Vec<(String, String)> = Vec::new();

    if let Some(status_eid) = first_i64(attrs, "logseq.property/status") {
        let ident = eid_to_ident.get(&status_eid).map(String::as_str);
        let (pith_state, downgraded_label) = match ident {
            Some("logseq.property/status.todo") => (Some("TODO"), None),
            Some("logseq.property/status.doing") => (Some("DOING"), None),
            Some("logseq.property/status.done") => (Some("DONE"), None),
            Some("logseq.property/status.canceled") => (Some("CANCELED"), None),
            Some("logseq.property/status.waiting") => (Some("WAITING"), None),
            Some("logseq.property/status.later") => (Some("LATER"), None),
            Some("logseq.property/status.now") => (Some("NOW"), None),
            Some("logseq.property/status.backlog") => (Some("LATER"), Some("Backlog")),
            Some("logseq.property/status.in-review") => (Some("WAITING"), Some("In Review")),
            _ => {
                let label = entities
                    .get(&status_eid)
                    .and_then(|a| first_str(a, "block/title"))
                    .unwrap_or("Unknown");
                (Some("TODO"), Some(label))
            }
        };
        if let Some(label) = downgraded_label {
            downgraded.record(
                "task_status_mapped",
                format!(
                    "block={block_id} status={label:?} -> {}",
                    pith_state.unwrap_or("TODO")
                ),
            );
            extra_props.push(("logseq-status".into(), label.to_string()));
        }
        if let Some(state) = pith_state
            && parser::parse_task_state(&content).is_none()
        {
            if content.is_empty() {
                content = state.to_string();
            } else {
                content = format!("{state} {content}");
            }
        }
    }

    if let Some(prio_eid) = first_i64(attrs, "logseq.property/priority") {
        let label = entities
            .get(&prio_eid)
            .and_then(|a| first_str(a, "block/title"))
            .map(str::to_string)
            .unwrap_or_else(|| prio_eid.to_string());
        downgraded.record(
            "task_priority_as_prop",
            format!("block={block_id} priority={label}"),
        );
        extra_props.push(("priority".into(), label));
    }

    for (attr_key, prop_name) in [
        ("logseq.property/scheduled", "scheduled"),
        ("logseq.property/deadline", "deadline"),
    ] {
        if let Some(vals) = attrs.get(attr_key)
            && !vals.is_empty()
        {
            let formatted =
                format_prop_values(vals, false, entities, page_eid_to_id, block_eid_to_id);
            if !formatted.is_empty() {
                downgraded.record(
                    &format!("task_{prop_name}_as_prop"),
                    format!("block={block_id} {prop_name}={formatted}"),
                );
                extra_props.push((prop_name.into(), formatted));
            }
        }
    }

    let mut user_tag_tokens: Vec<String> = Vec::new();
    for tag_eid in tags {
        if let Some(&tag_page_id) = page_eid_to_id.get(&tag_eid) {
            let uuid_str = tag_page_id.to_string();
            if !content.contains(&uuid_str) {
                user_tag_tokens.push(format!("#[[{uuid_str}]]"));
            }
        }
    }
    if !user_tag_tokens.is_empty() {
        let suffix = user_tag_tokens.join(" ");
        if let Some(nl) = content.find('\n') {
            let first = &content[..nl];
            let rest = &content[nl..];
            if first.is_empty() {
                content = format!("{suffix}{rest}");
            } else {
                content = format!("{first} {suffix}{rest}");
            }
        } else if content.is_empty() {
            content = suffix;
        } else {
            content = format!("{content} {suffix}");
        }
    }

    let mut user_prop_keys: Vec<&String> = attrs
        .keys()
        .filter(|k| k.starts_with("user.property/"))
        .collect();
    user_prop_keys.sort();
    for key in user_prop_keys {
        let vals = &attrs[key];
        let (prop_name, is_ref) = prop_defs.get(key).cloned().unwrap_or_else(|| {
            let tail = key.trim_start_matches("user.property/");
            (normalize_prop_key(tail), false)
        });
        let formatted = format_prop_values(vals, is_ref, entities, page_eid_to_id, block_eid_to_id);
        if !formatted.is_empty() {
            extra_props.push((prop_name, formatted));
        }
    }

    for (k, v) in extra_props {
        if !content.is_empty() {
            content.push('\n');
        }
        content.push_str(&format!("{k}:: {v}"));
    }

    content
}

fn rewrite_refs(
    block_id: Id,
    content: &str,
    kept_page_ids: &HashSet<Id>,
    kept_block_ids: &HashSet<Id>,
    uuid_to_title_all: &HashMap<Uuid, String>,
    unresolved_refs: &mut Vec<UnresolvedRef>,
) -> String {
    let mut out = String::with_capacity(content.len());
    for span in parser::tokenize(content) {
        match span {
            Span::Text(s) | Span::Code(s) => out.push_str(s),
            Span::PageLink { raw, target } => match target {
                RefTarget::Id(id) => {
                    if kept_page_ids.contains(&id) {
                        out.push_str(&format!("[[{id}]]"));
                    } else if kept_block_ids.contains(&id) {
                        out.push_str(&format!("(({id}))"));
                    } else {
                        unresolved_refs.push(UnresolvedRef {
                            source_block: block_id.to_string(),
                            kind: "page".into(),
                            target: id.to_string(),
                        });
                        if let Some(title) = uuid_to_title_all.get(&id.as_uuid()) {
                            out.push_str(title);
                        } else {
                            out.push_str(&format!("[missing:{}]", id.short_suffix(6)));
                        }
                    }
                }
                RefTarget::Title(_) => out.push_str(raw),
            },
            Span::BracketTag { raw, target } | Span::SimpleTag { raw, target } => match target {
                RefTarget::Id(id) => {
                    if kept_page_ids.contains(&id) {
                        out.push_str(&format!("#[[{id}]]"));
                    } else {
                        unresolved_refs.push(UnresolvedRef {
                            source_block: block_id.to_string(),
                            kind: "tag".into(),
                            target: id.to_string(),
                        });
                        if let Some(title) = uuid_to_title_all.get(&id.as_uuid()) {
                            out.push_str(title);
                        } else {
                            out.push_str(&format!("#missing:{}", id.short_suffix(6)));
                        }
                    }
                }
                RefTarget::Title(_) => out.push_str(raw),
            },
            Span::BlockRef { raw, id } => {
                if kept_block_ids.contains(&id) {
                    out.push_str(raw);
                } else {
                    unresolved_refs.push(UnresolvedRef {
                        source_block: block_id.to_string(),
                        kind: "block".into(),
                        target: id.to_string(),
                    });
                    out.push_str(raw);
                }
            }
        }
    }
    out
}

fn format_prop_values(
    vals: &[Value],
    is_ref: bool,
    entities: &EntityMap,
    page_eid_to_id: &HashMap<i64, Id>,
    block_eid_to_id: &HashMap<i64, Id>,
) -> String {
    let mut parts = Vec::with_capacity(vals.len());
    for v in vals {
        let rendered = match v {
            Value::Int(eid) if is_ref => {
                if let Some(&pid) = page_eid_to_id.get(eid) {
                    format!("[[{pid}]]")
                } else if let Some(&bid) = block_eid_to_id.get(eid) {
                    format!("(({bid}))")
                } else if let Some(title) =
                    entities.get(eid).and_then(|a| first_str(a, "block/title"))
                {
                    title.to_string()
                } else {
                    eid.to_string()
                }
            }
            Value::Int(n) => n.to_string(),
            Value::Float(f) => f.to_string(),
            Value::Bool(b) => b.to_string(),
            Value::String(s) => s.clone(),
            Value::Keyword(k) => k.clone(),
            Value::Symbol(s) => s.clone(),
            Value::Uuid(u) => u.to_string(),
            Value::Instant(ms) => chrono::DateTime::from_timestamp_millis(*ms)
                .map(|dt| dt.format("%Y-%m-%d").to_string())
                .unwrap_or_else(|| ms.to_string()),
            Value::Null => String::new(),
            Value::List(items) => {
                format_prop_values(items, is_ref, entities, page_eid_to_id, block_eid_to_id)
            }
            Value::Map(_) | Value::Tagged(_, _) => value_dedup_key(v),
        };
        if !rendered.is_empty() {
            parts.push(rendered);
        }
    }
    parts.join(", ")
}

fn normalize_prop_key(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.trim().chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            out.push(ch.to_ascii_lowercase());
        } else if (ch.is_whitespace() || ch == '/' || ch == '.')
            && !out.ends_with('-')
            && !out.is_empty()
        {
            out.push('-');
        }
    }
    let trimmed = out.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "prop".to_string()
    } else {
        trimmed
    }
}

fn apply_plan<F>(
    store: &mut Store,
    plan: &mut ImportPlan,
    options: &ImportOptions,
    on_progress: &mut F,
) -> Result<()>
where
    F: FnMut(usize, usize) -> bool,
{
    let live_pages = store.list_live_pages()?;
    let mut existing_page_ids: HashMap<Id, bool> = HashMap::with_capacity(live_pages.len());
    let mut existing_by_title: HashMap<String, Id> = HashMap::with_capacity(live_pages.len());
    let mut existing_by_day: HashMap<i32, Id> = HashMap::new();
    for p in live_pages {
        existing_page_ids.insert(p.id, p.favorite);
        existing_by_title.insert(p.title_lower, p.id);
        if let Some(day) = p.journal_day {
            existing_by_day.insert(day, p.id);
        }
    }

    let snapshot = store.live_snapshot()?;
    let existing_block_ids: HashSet<Id> = snapshot.blocks.keys().copied().collect();

    let mut page_id_remap: HashMap<Id, Id> = HashMap::new();
    let mut ops: Vec<Op> = Vec::new();
    let mut fav_ops: Vec<Op> = Vec::new();

    for page in &plan.pages {
        if let Some(&already_fav) = existing_page_ids.get(&page.id) {
            plan.report.pages_already_present += 1;
            if page.favorite && !already_fav {
                fav_ops.push(Op::SetPageFavorite {
                    id: page.id,
                    favorite: true,
                });
                plan.report.favorites_applied += 1;
            }
            continue;
        }
        if let Some(day) = page.journal_day
            && let Some(&existing_id) = existing_by_day.get(&day)
        {
            page_id_remap.insert(page.id, existing_id);
            plan.report.pages_already_present += 1;
            continue;
        }
        if let Some(&existing_id) = existing_by_title.get(&page.title_lower) {
            page_id_remap.insert(page.id, existing_id);
            plan.report.pages_already_present += 1;
            continue;
        }

        ops.push(Op::CreatePage {
            id: page.id,
            title: page.title.clone(),
            journal_day: page.journal_day,
            document_mode: false,
        });
        if page.journal_day.is_some() {
            plan.report.journals_imported += 1;
        } else {
            plan.report.pages_imported += 1;
        }
        if page.favorite {
            fav_ops.push(Op::SetPageFavorite {
                id: page.id,
                favorite: true,
            });
            plan.report.favorites_applied += 1;
        }
    }

    let mut collapse_ops: Vec<Op> = Vec::new();
    for block in &plan.blocks {
        if existing_block_ids.contains(&block.id) {
            plan.report.blocks_already_present += 1;
            continue;
        }
        let page_id = page_id_remap
            .get(&block.page_id)
            .copied()
            .unwrap_or(block.page_id);
        let content = if page_id_remap.is_empty() {
            block.content.clone()
        } else {
            remap_content_page_ids(&block.content, &page_id_remap)
        };
        ops.push(Op::InsertBlock {
            id: block.id,
            page_id,
            parent_id: block.parent_id,
            order_key: block.order_key.clone(),
            content,
        });
        plan.report.blocks_imported += 1;
        if block.collapsed {
            collapse_ops.push(Op::SetCollapsed {
                id: block.id,
                collapsed: true,
            });
            plan.report.collapsed_applied += 1;
        }
    }

    ops.extend(collapse_ops);
    ops.extend(fav_ops);

    let total = ops.len();
    if total == 0 {
        return Ok(());
    }

    let chunk_size = options.chunk_size.max(1);
    let meta = TxMeta::new(Origin::Import, &options.actor, "import logseq db");
    let mut done = 0usize;

    for chunk in ops.chunks(chunk_size) {
        if !on_progress(done, total) {
            return Err(Error::Cancelled);
        }
        store.apply_ops(chunk, &meta)?;
        plan.report.txns_written += 1;
        done += chunk.len();
    }
    let _ = on_progress(total, total);
    Ok(())
}

fn remap_content_page_ids(content: &str, remap: &HashMap<Id, Id>) -> String {
    let mut out = String::with_capacity(content.len());
    for span in parser::tokenize(content) {
        match span {
            Span::PageLink {
                target: RefTarget::Id(id),
                ..
            } => {
                let mapped = remap.get(&id).copied().unwrap_or(id);
                out.push_str(&format!("[[{mapped}]]"));
            }
            Span::BracketTag {
                target: RefTarget::Id(id),
                ..
            }
            | Span::SimpleTag {
                target: RefTarget::Id(id),
                ..
            } => {
                let mapped = remap.get(&id).copied().unwrap_or(id);
                out.push_str(&format!("#[[{mapped}]]"));
            }
            Span::Text(s) | Span::Code(s) => out.push_str(s),
            Span::PageLink { raw, .. }
            | Span::BracketTag { raw, .. }
            | Span::SimpleTag { raw, .. }
            | Span::BlockRef { raw, .. } => out.push_str(raw),
        }
    }
    out
}
