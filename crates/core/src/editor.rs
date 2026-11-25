use crate::api::{MarkdownNode, parse_markdown_tree};
use crate::error::{Error, Result};
use crate::id::Id;
use crate::journal::resolve_journal_date;
use crate::ops::Op;
use crate::order;
use crate::parser;
use crate::store::{Store, known_links};
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
                content: self.pin_links(after, &[id])?,
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
                content: format!("{previous_text}{}", self.pin_links(text, &[id])?),
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

    pub fn move_block_up(
        &mut self,
        id: Id,
        base_version: i64,
        meta: &TxMeta,
    ) -> Result<Option<EditOutcome>> {
        let block = self.live_block(id)?;
        let siblings = self.list_children(block.page_id, block.parent_id)?;
        let position = sibling_position(&siblings, id)?;
        if position == 0 {
            return Ok(None);
        }
        let lower = position
            .checked_sub(2)
            .map(|p| siblings[p].order_key.clone());
        let upper = siblings[position - 1].order_key.clone();
        self.move_among_siblings(&block, base_version, lower.as_deref(), Some(&upper), meta)
    }

    pub fn move_block_down(
        &mut self,
        id: Id,
        base_version: i64,
        meta: &TxMeta,
    ) -> Result<Option<EditOutcome>> {
        let block = self.live_block(id)?;
        let siblings = self.list_children(block.page_id, block.parent_id)?;
        let position = sibling_position(&siblings, id)?;
        let Some(next) = siblings.get(position + 1) else {
            return Ok(None);
        };
        let upper = siblings.get(position + 2).map(|b| b.order_key.clone());
        self.move_among_siblings(
            &block,
            base_version,
            Some(&next.order_key),
            upper.as_deref(),
            meta,
        )
    }

    fn move_among_siblings(
        &mut self,
        block: &Block,
        base_version: i64,
        lower: Option<&str>,
        upper: Option<&str>,
        meta: &TxMeta,
    ) -> Result<Option<EditOutcome>> {
        let result = self.apply_ops(
            &[Op::MoveBlock {
                id: block.id,
                page_id: block.page_id,
                parent_id: block.parent_id,
                order_key: order::between(lower, upper)?,
                expected_version: Some(base_version),
            }],
            meta,
        )?;
        Ok(Some(EditOutcome {
            result,
            focus_block: block.id,
            cursor: None,
        }))
    }

    pub fn reveal_block(&mut self, id: Id, meta: &TxMeta) -> Result<u64> {
        let mut expand = Vec::new();
        let mut parent = self.live_block(id)?.parent_id;
        while let Some(parent_id) = parent {
            let ancestor = self.live_block(parent_id)?;
            if ancestor.collapsed {
                expand.push(Op::SetCollapsed {
                    id: ancestor.id,
                    collapsed: false,
                });
            }
            parent = ancestor.parent_id;
        }
        if !expand.is_empty() {
            self.apply_ops(&expand, meta)?;
        }
        self.visible_index(id)?.ok_or(Error::NotFound(id))
    }

    pub fn paste_text(
        &mut self,
        id: Id,
        base_version: i64,
        before: &str,
        after: &str,
        pasted: &str,
        meta: &TxMeta,
    ) -> Result<Option<EditOutcome>> {
        let mut nodes = parse_paste(pasted);
        if nodes.len() < 2 && nodes.iter().all(|n| n.children.is_empty()) {
            return Ok(None);
        }
        let block = self.live_block(id)?;
        let first = nodes.remove(0);
        let mut ops = Vec::new();
        let mut focus = (id, 0usize);

        let first_children_upper = self
            .list_children(block.page_id, Some(id))?
            .first()
            .map(|b| b.order_key.clone());
        let mut first_text = format!("{before}{}", first.content);
        if nodes.is_empty() && first.children.is_empty() {
            first_text.push_str(after);
        }
        focus.1 = before.chars().count() + first.content.chars().count();
        insert_tree(
            &first.children,
            block.page_id,
            Some(id),
            None,
            first_children_upper.as_deref(),
            &mut ops,
        )?;

        let siblings = self.list_children(block.page_id, block.parent_id)?;
        let upper = sibling_after(&siblings, id)?;
        let mut lower = block.order_key.clone();
        let count = nodes.len();
        for (index, node) in nodes.into_iter().enumerate() {
            let key = order::between(Some(&lower), upper.as_deref())?;
            let node_id = Id::new();
            let is_last = index + 1 == count;
            let content = if is_last {
                format!("{}{after}", node.content)
            } else {
                node.content.clone()
            };
            ops.push(Op::InsertBlock {
                id: node_id,
                page_id: block.page_id,
                parent_id: block.parent_id,
                order_key: key.clone(),
                content,
            });
            insert_tree(
                &node.children,
                block.page_id,
                Some(node_id),
                None,
                None,
                &mut ops,
            )?;
            if is_last {
                focus = (node_id, node.content.chars().count());
            }
            lower = key;
        }
        if count == 0 && !first.children.is_empty() {
            first_text.push_str(after);
        }

        ops.insert(
            0,
            Op::UpdateBlock {
                id,
                content: first_text,
                expected_version: Some(base_version),
            },
        );
        let result = self.apply_ops(&ops, meta)?;
        Ok(Some(EditOutcome {
            result,
            focus_block: focus.0,
            cursor: Some(focus.1 as u32),
        }))
    }

    pub fn subtree_markdown(&self, id: Id) -> Result<String> {
        let block = self.live_block(id)?;
        let mut lines = Vec::new();
        self.write_markdown(&block, 0, &mut lines)?;
        Ok(lines.join("\n"))
    }

    fn write_markdown(&self, block: &Block, depth: usize, lines: &mut Vec<String>) -> Result<()> {
        let indent = "  ".repeat(depth);
        let rendered = self.render_content(&block.content)?;
        let mut content_lines = rendered.lines();
        lines.push(format!(
            "{indent}- {}",
            content_lines.next().unwrap_or_default()
        ));
        for line in content_lines {
            lines.push(format!("{indent}  {line}"));
        }
        for child in self.list_children(block.page_id, Some(block.id))? {
            self.write_markdown(&child, depth + 1, lines)?;
        }
        Ok(())
    }

    fn pin_links(&self, text: &str, blocks: &[Id]) -> Result<String> {
        let known = known_links(self.conn(), blocks)?;
        Ok(parser::pin_known_titles(text, |title| {
            known.get(&title.to_lowercase()).copied()
        }))
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

pub fn parse_paste(text: &str) -> Vec<MarkdownNode> {
    let has_bullets = text
        .lines()
        .find(|l| !l.trim().is_empty())
        .is_some_and(|l| l.trim_start().starts_with("- ") || l.trim_start().starts_with("* "));
    if has_bullets {
        return parse_markdown_tree(text).unwrap_or_default();
    }
    let normalized = text.replace("\r\n", "\n");
    normalized
        .split("\n\n")
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| MarkdownNode {
            content: p.to_string(),
            children: Vec::new(),
        })
        .collect()
}

fn insert_tree(
    nodes: &[MarkdownNode],
    page_id: Id,
    parent_id: Option<Id>,
    lower: Option<&str>,
    upper: Option<&str>,
    ops: &mut Vec<Op>,
) -> Result<()> {
    let mut previous = lower.map(str::to_string);
    for node in nodes {
        let key = order::between(previous.as_deref(), upper)?;
        let id = Id::new();
        ops.push(Op::InsertBlock {
            id,
            page_id,
            parent_id,
            order_key: key.clone(),
            content: node.content.clone(),
        });
        insert_tree(&node.children, page_id, Some(id), None, None, ops)?;
        previous = Some(key);
    }
    Ok(())
}
