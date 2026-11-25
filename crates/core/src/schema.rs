use rusqlite::{Connection, TransactionBehavior};

use crate::error::Result;

const CURRENT_SCHEMA_VERSION: i64 = 2;

const MIGRATION_V1: &str = "
CREATE TABLE pages (
    seq INTEGER PRIMARY KEY,
    id BLOB NOT NULL UNIQUE,
    id_rev TEXT NOT NULL,
    title TEXT NOT NULL,
    title_lower TEXT NOT NULL,
    journal_day INTEGER,
    document_mode INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    created_by TEXT NOT NULL,
    updated_by TEXT NOT NULL,
    deleted_at INTEGER,
    version INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX idx_pages_id_rev ON pages(id_rev);

CREATE UNIQUE INDEX idx_pages_title_lower_live
    ON pages(title_lower) WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX idx_pages_journal_day_live
    ON pages(journal_day) WHERE deleted_at IS NULL;

CREATE TABLE blocks (
    seq INTEGER PRIMARY KEY,
    id BLOB NOT NULL UNIQUE,
    id_rev TEXT NOT NULL,
    page_id BLOB NOT NULL,
    parent_id BLOB,
    order_key TEXT NOT NULL,
    content TEXT NOT NULL,
    collapsed INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    created_by TEXT NOT NULL,
    updated_by TEXT NOT NULL,
    deleted_at INTEGER,
    version INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX idx_blocks_id_rev ON blocks(id_rev);

CREATE INDEX idx_blocks_parent_order
    ON blocks(parent_id, order_key, id);

CREATE INDEX idx_blocks_page
    ON blocks(page_id);

CREATE TABLE refs (
    src_block BLOB NOT NULL,
    kind TEXT NOT NULL,
    target BLOB NOT NULL
);

CREATE INDEX idx_refs_target ON refs(target);
CREATE INDEX idx_refs_src ON refs(src_block);

CREATE TABLE props (
    block_id BLOB NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    value_ref BLOB
);

CREATE INDEX idx_props_key_value ON props(key, value);
CREATE INDEX idx_props_block ON props(block_id);

CREATE TABLE tasks (
    block_id BLOB PRIMARY KEY,
    state TEXT NOT NULL
);

CREATE VIRTUAL TABLE blocks_fts USING fts5(
    text,
    tokenize='trigram'
);

CREATE VIRTUAL TABLE pages_fts USING fts5(
    title,
    tokenize='trigram'
);

CREATE TABLE txns (
    seq INTEGER PRIMARY KEY,
    id BLOB NOT NULL UNIQUE,
    id_rev TEXT NOT NULL,
    ts INTEGER NOT NULL,
    origin TEXT NOT NULL,
    actor TEXT NOT NULL,
    session TEXT,
    summary TEXT NOT NULL,
    undoes BLOB
);

CREATE INDEX idx_txns_id_rev ON txns(id_rev);
CREATE INDEX idx_txns_undoes ON txns(undoes);

CREATE TABLE ops (
    txn_id BLOB NOT NULL,
    seq INTEGER NOT NULL,
    forward TEXT NOT NULL,
    inverse TEXT NOT NULL,
    PRIMARY KEY (txn_id, seq)
);

CREATE TABLE txn_blocks (
    txn_id BLOB NOT NULL,
    block_id BLOB NOT NULL,
    PRIMARY KEY (txn_id, block_id)
);

CREATE INDEX idx_txn_blocks_entity ON txn_blocks(block_id, txn_id);
";

const MIGRATION_V2: &str = "
ALTER TABLE txns ADD COLUMN undo_group TEXT;
CREATE INDEX idx_txns_actor_undo_group ON txns(actor, undo_group);
";

pub fn configure_and_migrate(conn: &mut Connection) -> Result<()> {
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA foreign_keys = ON;",
    )?;

    let version: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version < CURRENT_SCHEMA_VERSION {
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if version < 1 {
            tx.execute_batch(MIGRATION_V1)?;
            tx.pragma_update(None, "user_version", 1)?;
        }
        if version < 2 {
            tx.execute_batch(MIGRATION_V2)?;
            tx.pragma_update(None, "user_version", 2)?;
        }
        tx.commit()?;
    }

    Ok(())
}
