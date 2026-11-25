use crate::error::{Error, Result};
use crate::id::Id;
use crate::journal::resolve_journal_date;
use crate::ops::Op;
use crate::order;
use crate::parser;
use crate::store::Store;
use crate::types::{Block, EditOutcome, TxMeta};

impl Store {
    pub fn start_journal(&mut self, date: Option<&str>, meta: &TxMeta) -> Result<EditOutcome> {
        let (journal_day, title) = resolve_journal_date(date)?;
        let mut ops = Vec::new();
        let page_id = match self.journal_page(date)? {
            Some(page) => page.id,
            None => {
                let id = Id::new();
                ops.push(Op::CreatePage {
                    id,
                    title,
                    journal_day: Some(journal_day),
                    document_mode: false,
                });
                id
            }
        };
        self.append_root_block(page_id, ops, "", meta)
    }

    pub fn append_block(&mut self, page_id: Id, text: &str, meta: &TxMeta) -> Result<EditOutcome> {
        self.append_root_block(page_id, Vec::new(), text, meta)
    }

    pub fn split_block(
        &mut self,
        id: Id,
        base_version: i64,
        before: &str,
        after: &str,
        meta: &TxMeta,
    ) -> Result<EditOutcome> {
        let block = self.live_block(id)?;
        let children = self.list_children(block.page_id, Some(id))?;
        let (parent_id, lower, upper) = if !children.is_empty() && !block.collapsed {
            (
                Some(id),
                None,
                children.first().map(|c| c.order_key.clone()),
            )
        } else {
            let siblings = self.list_children(block.page_id, block.parent_id)?;
            let next = sibling_after(&siblings, id)?;
            (block.parent_id, Some(block.order_key.clone()), next)
        };

        let new_id = Id::new();
        let ops = vec![
            Op::UpdateBlock {
                id,
                content: before.to_string(),
                expected_version: Some(base_version),
            },
            Op::InsertBlock {
                id: new_id,
                page_id: block.page_id,
                parent_id,
                order_key: order::between(lower.as_deref(), upper.as_deref())?,
                content: after.to_string(),
            },
        ];
        let result = self.apply_ops(&ops, meta)?;
        Ok(EditOutcome {
            result,
            focus_block: new_id,
            cursor: Some(0),
        })
    }

    pub fn merge_into_previous(
        &mut self,
        id: Id,
        base_version: i64,
        text: &str,
        meta: &TxMeta,
    ) -> Result<Option<EditOutcome>> {
        let block = self.live_block(id)?;
        if !self.list_children(block.page_id, Some(id))?.is_empty() {
            return Ok(None);
        }
        let visible = self.visible_blocks(block.page_id)?;
        let position = visible
            .iter()
            .position(|v| v.block.id == id)
            .ok_or(Error::NotFound(id))?;
        let Some(previous) = position.checked_sub(1).map(|p| visible[p].block.clone()) else {
            return Ok(None);
        };

        let previous_text = self.render_content(&previous.content)?;
        let cursor = previous_text.chars().count() as u32;
        let mut ops = Vec::new();
        if !text.is_empty() {
            ops.push(Op::UpdateBlock {
                id: previous.id,
                content: format!("{previous_text}{text}"),
                expected_version: Some(previous.version),
            });
        }
        ops.push(Op::DeleteBlock {
            id,
            expected_version: Some(base_version),
        });
        let result = self.apply_ops(&ops, meta)?;
        Ok(Some(EditOutcome {
            result,
            focus_block: previous.id,
            cursor: Some(cursor),
        }))
    }

    pub fn indent_block(
        &mut self,
        id: Id,
        base_version: i64,
        meta: &TxMeta,
    ) -> Result<Option<EditOutcome>> {
        let block = self.live_block(id)?;
        let siblings = self.list_children(block.page_id, block.parent_id)?;
        let position = sibling_position(&siblings, id)?;
        let Some(new_parent) = position.checked_sub(1).map(|p| siblings[p].clone()) else {
            return Ok(None);
        };

        let last_child_key = self
            .list_children(block.page_id, Some(new_parent.id))?
            .last()
            .map(|b| b.order_key.clone());
        let mut ops = Vec::new();
        if new_parent.collapsed {
            ops.push(Op::SetCollapsed {
                id: new_parent.id,
                collapsed: false,
            });
        }
        ops.push(Op::MoveBlock {
            id,
            page_id: block.page_id,
            parent_id: Some(new_parent.id),
            order_key: order::between(last_child_key.as_deref(), None)?,
            expected_version: Some(base_version),
        });
        let result = self.apply_ops(&ops, meta)?;
        Ok(Some(EditOutcome {
            result,
            focus_block: id,
            cursor: None,
        }))
    }

    pub fn outdent_block(
        &mut self,
        id: Id,
        base_version: i64,
        meta: &TxMeta,
    ) -> Result<Option<EditOutcome>> {
        let block = self.live_block(id)?;
        let Some(parent_id) = block.parent_id else {
            return Ok(None);
        };
        let parent = self.live_block(parent_id)?;
        let parent_siblings = self.list_children(block.page_id, parent.parent_id)?;
        let next = sibling_after(&parent_siblings, parent.id)?;

        let ops = vec![Op::MoveBlock {
            id,
            page_id: block.page_id,
            parent_id: parent.parent_id,
            order_key: order::between(Some(&parent.order_key), next.as_deref())?,
            expected_version: Some(base_version),
        }];
        let result = self.apply_ops(&ops, meta)?;
        Ok(Some(EditOutcome {
            result,
            focus_block: id,
            cursor: None,
        }))
    }

    pub fn cycle_task(&mut self, id: Id, base_version: i64, meta: &TxMeta) -> Result<EditOutcome> {
        self.set_task_state_with(id, base_version, meta, next_task_state)
    }

    pub fn toggle_task_done(
        &mut self,
        id: Id,
        base_version: i64,
        meta: &TxMeta,
    ) -> Result<EditOutcome> {
        self.set_task_state_with(id, base_version, meta, |current| match current {
            Some("DONE") => Some("TODO"),
            _ => Some("DONE"),
        })
    }

    fn set_task_state_with(
        &mut self,
        id: Id,
        base_version: i64,
        meta: &TxMeta,
        next: impl Fn(Option<&str>) -> Option<&'static str>,
    ) -> Result<EditOutcome> {
        let block = self.live_block(id)?;
        let rendered = self.render_content(&block.content)?;
        let current = parser::parse_task_state(&rendered);
        let content = parser::set_task_state_in_content(&rendered, next(current.as_deref()));
        let result = self.apply_ops(
            &[Op::UpdateBlock {
                id,
                content,
                expected_version: Some(base_version),
            }],
            meta,
        )?;
        Ok(EditOutcome {
            result,
            focus_block: id,
            cursor: None,
        })
    }

    fn append_root_block(
        &mut self,
        page_id: Id,
        mut ops: Vec<Op>,
        text: &str,
        meta: &TxMeta,
    ) -> Result<EditOutcome> {
        let last_key = self
            .list_children(page_id, None)?
            .last()
            .map(|b| b.order_key.clone());
        let id = Id::new();
        ops.push(Op::InsertBlock {
            id,
            page_id,
            parent_id: None,
            order_key: order::between(last_key.as_deref(), None)?,
            content: text.to_string(),
        });
        let result = self.apply_ops(&ops, meta)?;
        Ok(EditOutcome {
            result,
            focus_block: id,
            cursor: Some(text.chars().count() as u32),
        })
    }

    fn live_block(&self, id: Id) -> Result<Block> {
        let block = self.get_block(id)?.ok_or(Error::NotFound(id))?;
        if block.deleted_at.is_some() {
            return Err(Error::DeletedEntity(id));
        }
        Ok(block)
    }
}

fn sibling_position(siblings: &[Block], id: Id) -> Result<usize> {
    siblings
        .iter()
        .position(|b| b.id == id)
        .ok_or(Error::NotFound(id))
}

fn sibling_after(siblings: &[Block], id: Id) -> Result<Option<String>> {
    let position = sibling_position(siblings, id)?;
    Ok(siblings.get(position + 1).map(|b| b.order_key.clone()))
}

pub fn next_task_state(current: Option<&str>) -> Option<&'static str> {
    match current {
        None => Some("TODO"),
        Some("TODO") => Some("DOING"),
        Some("DOING") | Some("NOW") => Some("DONE"),
        Some("DONE") => None,
        Some(_) => Some("TODO"),
    }
}
