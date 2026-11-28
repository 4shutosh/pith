pub mod export;
pub mod logseq;
pub mod transit;

use std::path::PathBuf;

use thiserror::Error;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Error)]
pub enum Error {
    #[error("core error: {0}")]
    Core(#[from] pith_core::Error),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("transit decode error: {0}")]
    Transit(String),

    #[error("missing Logseq schema version datom")]
    MissingSchemaVersion,

    #[error("unsupported Logseq schema version {major}.{minor} (expected major version 65)")]
    UnsupportedSchemaVersion { major: i64, minor: i64 },

    #[error("invalid Logseq database layout: {0}")]
    InvalidLogseqDb(String),

    #[error("refusing to export into Logseq graph directory: {}", .0.display())]
    RefusedLogseqGraphDir(PathBuf),

    #[error("operation cancelled")]
    Cancelled,
}

impl Error {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Core(e) => e.code(),
            Self::Io(_) => "io_error",
            Self::Sqlite(_) => "sqlite_error",
            Self::Json(_) => "json_error",
            Self::Transit(_) => "transit_error",
            Self::MissingSchemaVersion => "missing_schema_version",
            Self::UnsupportedSchemaVersion { .. } => "unsupported_schema_version",
            Self::InvalidLogseqDb(_) => "invalid_logseq_db",
            Self::RefusedLogseqGraphDir(_) => "refused_logseq_graph_dir",
            Self::Cancelled => "cancelled",
        }
    }
}

pub use export::{ExportOptions, ExportReport, export_markdown, export_markdown_with_progress};
pub use logseq::{
    DowngradeSample, ImportOptions, ImportReport, SkippedCounts, UnresolvedRef, import_logseq_db,
    import_logseq_db_with_progress,
};
