use std::collections::VecDeque;

use serde::{Deserialize, Serialize};

use crate::error::Error;

/// One page of a list, and where the next one starts.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Page<T> {
    /// The page's items.
    pub items: Vec<T>,
    /// The cursor of the next page, or None on the last one.
    pub next_cursor: Option<String>,
    /// Another page follows.
    pub has_more: bool,
}

/// Walks pages from `cursor` (the first page when None) until the last one,
/// yielding every item. A page is fetched only when the items before it were
/// taken, and an error ends the walk.
pub(crate) fn iterate<'a, T: 'a>(
    cursor: Option<String>,
    mut fetch: impl FnMut(Option<String>) -> Result<Page<T>, Error> + 'a,
) -> impl Iterator<Item = Result<T, Error>> + 'a {
    let mut next = cursor;
    let mut items = VecDeque::new();
    let mut done = false;
    std::iter::from_fn(move || loop {
        if let Some(item) = items.pop_front() {
            return Some(Ok(item));
        }
        if done {
            return None;
        }
        match fetch(next.take()) {
            Ok(page) => {
                match page.next_cursor {
                    Some(cursor) if page.has_more && !cursor.is_empty() => next = Some(cursor),
                    _ => done = true,
                }
                items.extend(page.items);
            }
            Err(error) => {
                done = true;
                return Some(Err(error));
            }
        }
    })
}
