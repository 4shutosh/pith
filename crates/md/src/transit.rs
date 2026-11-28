use serde_json::Value as JsonValue;
use uuid::Uuid;

use crate::{Error, Result};

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
    Keyword(String),
    Symbol(String),
    Uuid(Uuid),
    Instant(i64),
    List(Vec<Value>),
    Map(Vec<(Value, Value)>),
    Tagged(String, Box<Value>),
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(s) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn as_keyword(&self) -> Option<&str> {
        match self {
            Self::Keyword(k) => Some(k.as_str()),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Self::Int(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_uuid(&self) -> Option<Uuid> {
        match self {
            Self::Uuid(u) => Some(*u),
            _ => None,
        }
    }

    pub fn as_list(&self) -> Option<&[Value]> {
        match self {
            Self::List(items) => Some(items.as_slice()),
            _ => None,
        }
    }

    pub fn map_get_keyword(&self, keyword: &str) -> Option<&Value> {
        match self {
            Self::Map(entries) => entries.iter().find_map(|(k, v)| match k {
                Self::Keyword(kw) if kw == keyword => Some(v),
                _ => None,
            }),
            _ => None,
        }
    }
}

pub fn decode(input: &str) -> Result<Value> {
    let raw: JsonValue = serde_json::from_str(input)?;
    let mut cache: Vec<String> = Vec::new();
    decode_node(&raw, false, &mut cache)
}

fn decode_node(node: &JsonValue, as_key: bool, cache: &mut Vec<String>) -> Result<Value> {
    match node {
        JsonValue::Null => Ok(Value::Null),
        JsonValue::Bool(b) => Ok(Value::Bool(*b)),
        JsonValue::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(Value::Int(i))
            } else if let Some(u) = n.as_u64() {
                i64::try_from(u)
                    .map(Value::Int)
                    .map_err(|_| Error::Transit(format!("integer overflow: {u}")))
            } else if let Some(f) = n.as_f64() {
                Ok(Value::Float(f))
            } else {
                Err(Error::Transit(format!("unsupported number: {n}")))
            }
        }
        JsonValue::String(s) => decode_string(s, as_key, cache),
        JsonValue::Array(arr) => decode_array(arr, cache),
        JsonValue::Object(obj) => {
            let mut entries = Vec::with_capacity(obj.len());
            for (k, v) in obj {
                let dk = decode_string(k, true, cache)?;
                let dv = decode_node(v, false, cache)?;
                entries.push((dk, dv));
            }
            Ok(Value::Map(entries))
        }
    }
}

fn is_cacheable(raw: &str, as_key: bool) -> bool {
    if raw.len() < 4 {
        return false;
    }
    if as_key {
        return true;
    }
    raw.starts_with("~:") || raw.starts_with("~$") || raw.starts_with("~#")
}

fn decode_cache_index(code: &str) -> Result<usize> {
    let bytes = code.as_bytes();
    if bytes.len() < 2 || bytes[0] != b'^' {
        return Err(Error::Transit(format!("invalid cache ref: {code}")));
    }
    let mut idx: usize = 0;
    for &b in &bytes[1..] {
        if b < 48 {
            return Err(Error::Transit(format!("invalid cache code byte in {code}")));
        }
        idx = idx
            .checked_mul(44)
            .and_then(|v| v.checked_add((b - 48) as usize))
            .ok_or_else(|| Error::Transit(format!("cache index overflow in {code}")))?;
    }
    Ok(idx)
}

fn decode_string(s: &str, as_key: bool, cache: &mut Vec<String>) -> Result<Value> {
    if s.starts_with('^') && s != "^ " {
        let idx = decode_cache_index(s)?;
        let cached = cache
            .get(idx)
            .ok_or_else(|| Error::Transit(format!("cache index {idx} out of bounds for {s}")))?
            .clone();
        return interpret_string(&cached);
    }

    if is_cacheable(s, as_key) {
        cache.push(s.to_string());
    }
    interpret_string(s)
}

fn interpret_string(s: &str) -> Result<Value> {
    let bytes = s.as_bytes();
    if bytes.len() >= 2 && bytes[0] == b'~' {
        match bytes[1] {
            b':' => Ok(Value::Keyword(s[2..].to_string())),
            b'$' => Ok(Value::Symbol(s[2..].to_string())),
            b'#' => Ok(Value::Tagged(s[2..].to_string(), Box::new(Value::Null))),
            b'u' => {
                let uuid = Uuid::parse_str(&s[2..])
                    .map_err(|e| Error::Transit(format!("invalid uuid {s}: {e}")))?;
                Ok(Value::Uuid(uuid))
            }
            b'm' => {
                let ms: i64 = s[2..]
                    .parse()
                    .map_err(|e| Error::Transit(format!("invalid instant {s}: {e}")))?;
                Ok(Value::Instant(ms))
            }
            b't' => {
                let dt = chrono::DateTime::parse_from_rfc3339(&s[2..])
                    .map_err(|e| Error::Transit(format!("invalid rfc3339 instant {s}: {e}")))?;
                Ok(Value::Instant(dt.timestamp_millis()))
            }
            b'i' => {
                let n: i64 = s[2..]
                    .parse()
                    .map_err(|e| Error::Transit(format!("invalid transit int {s}: {e}")))?;
                Ok(Value::Int(n))
            }
            b'd' => {
                let f: f64 = s[2..]
                    .parse()
                    .map_err(|e| Error::Transit(format!("invalid transit float {s}: {e}")))?;
                Ok(Value::Float(f))
            }
            b'~' | b'^' | b'`' => Ok(Value::String(s[1..].to_string())),
            b'r' | b'n' | b'f' | b'c' | b'b' | b'z' => Ok(Value::String(s[2..].to_string())),
            _ => Ok(Value::String(s.to_string())),
        }
    } else {
        Ok(Value::String(s.to_string()))
    }
}

fn decode_array(arr: &[JsonValue], cache: &mut Vec<String>) -> Result<Value> {
    if let Some(JsonValue::String(first)) = arr.first() {
        if first == "^ " {
            if !(arr.len() - 1).is_multiple_of(2) {
                return Err(Error::Transit("map array has odd number of entries".into()));
            }
            let mut entries = Vec::with_capacity((arr.len() - 1) / 2);
            let mut i = 1;
            while i < arr.len() {
                let k = decode_node(&arr[i], true, cache)?;
                let v = decode_node(&arr[i + 1], false, cache)?;
                entries.push((k, v));
                i += 2;
            }
            return Ok(Value::Map(entries));
        }

        if arr.len() == 2 && (first.starts_with("~#") || (first.starts_with('^') && first != "^ "))
        {
            let tag_candidate = decode_string(first, first.starts_with("~#"), cache)?;
            if let Value::Tagged(tag, _) = tag_candidate {
                let payload = decode_node(&arr[1], false, cache)?;
                return Ok(Value::Tagged(tag, Box::new(payload)));
            }
            let second = decode_node(&arr[1], false, cache)?;
            return Ok(Value::List(vec![tag_candidate, second]));
        }
    }

    let mut items = Vec::with_capacity(arr.len());
    for item in arr {
        items.push(decode_node(item, false, cache)?);
    }
    Ok(Value::List(items))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_map_keywords_and_cache_refs() {
        let input = r#"["^ ","~:block/title","hello","~:block/order","a0","~:nested",["^ ","^0","world","^1","a1"]]"#;
        let val = decode(input).expect("decode map");
        assert_eq!(
            val.map_get_keyword("block/title").and_then(Value::as_str),
            Some("hello")
        );
        let nested = val.map_get_keyword("nested").expect("nested map");
        assert_eq!(
            nested
                .map_get_keyword("block/title")
                .and_then(Value::as_str),
            Some("world")
        );
        assert_eq!(
            nested
                .map_get_keyword("block/order")
                .and_then(Value::as_str),
            Some("a1")
        );
    }

    #[test]
    fn decodes_uuids_instants_and_escaped_strings() {
        let input = r#"["~u698f9847-f365-4a25-b1e4-243e3394ce99","~m1771018311144","~t2026-02-14T12:00:00Z","~```rust\nfn main() {}\n```","~~tilde","~^caret"]"#;
        let val = decode(input).expect("decode scalars");
        let list = val.as_list().expect("list");
        assert_eq!(
            list[0],
            Value::Uuid(Uuid::parse_str("698f9847-f365-4a25-b1e4-243e3394ce99").expect("uuid"))
        );
        assert_eq!(list[1], Value::Instant(1_771_018_311_144));
        assert_eq!(list[2], Value::Instant(1_771_070_400_000));
        assert_eq!(list[3], Value::String("```rust\nfn main() {}\n```".into()));
        assert_eq!(list[4], Value::String("~tilde".into()));
        assert_eq!(list[5], Value::String("^caret".into()));
    }

    #[test]
    fn decodes_tagged_values_and_int_keys() {
        let input = r#"["^ ","~i32",["~#set",[1,2,3]]]"#;
        let val = decode(input).expect("decode tagged");
        assert_eq!(
            val,
            Value::Map(vec![(
                Value::Int(32),
                Value::Tagged(
                    "set".into(),
                    Box::new(Value::List(vec![
                        Value::Int(1),
                        Value::Int(2),
                        Value::Int(3)
                    ]))
                )
            )])
        );
    }

    #[test]
    fn decodes_two_char_base44_cache_ref() {
        let mut entries = String::from(r#"["^ ""#);
        for i in 0..45 {
            entries.push_str(&format!(r#","~:k{i:03}",{i}"#));
        }
        entries.push_str(r#","~:check","^10"]"#);
        let val = decode(&entries).expect("decode 45 keys");
        assert_eq!(
            val.map_get_keyword("check").and_then(Value::as_keyword),
            Some("k044")
        );
    }

    #[test]
    fn rejects_out_of_bounds_cache_ref() {
        let err = decode(r#"["^0"]"#).expect_err("must fail");
        assert!(matches!(err, Error::Transit(_)));
    }
}
