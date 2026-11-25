use crate::error::{Error, Result};

const ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const BASE: usize = 62;
const MID_IDX: usize = BASE / 2;

fn char_to_digit(c: u8) -> Result<usize> {
    ALPHABET
        .binary_search(&c)
        .map_err(|_| Error::InvalidOrderChar(c as char))
}

fn digit_to_char(d: usize) -> char {
    ALPHABET[d] as char
}

fn validate_key(key: &str) -> Result<()> {
    if key.is_empty() {
        return Err(Error::InvalidOrderChar('\0'));
    }
    for &b in key.as_bytes() {
        char_to_digit(b)?;
    }
    Ok(())
}

pub fn between(lower: Option<&str>, upper: Option<&str>) -> Result<String> {
    if let Some(l) = lower {
        validate_key(l)?;
    }
    if let Some(u) = upper {
        validate_key(u)?;
    }
    if let (Some(l), Some(u)) = (lower, upper)
        && l >= u
    {
        return Err(Error::InvalidOrderBounds {
            lower: Some(l.to_string()),
            upper: Some(u.to_string()),
        });
    }

    match (lower, upper) {
        (None, None) => Ok(digit_to_char(MID_IDX).to_string()),
        (Some(l), None) => after(l),
        (None, Some(u)) => before(u),
        (Some(l), Some(u)) => midpoint(l, u),
    }
}

fn after(lower: &str) -> Result<String> {
    let bytes = lower.as_bytes();
    let last = char_to_digit(bytes[bytes.len() - 1])?;
    if last + 1 < BASE {
        let mut out = lower[..bytes.len() - 1].to_string();
        out.push(digit_to_char(last + 1));
        return Ok(out);
    }
    let mut out = lower.to_string();
    out.push(digit_to_char(MID_IDX));
    Ok(out)
}

fn before(upper: &str) -> Result<String> {
    let bytes = upper.as_bytes();
    let mut prefix = String::new();
    for &b in bytes {
        let d = char_to_digit(b)?;
        if d > 1 {
            prefix.push(digit_to_char(d / 2));
            return Ok(prefix);
        }
        if d == 1 {
            prefix.push(digit_to_char(0));
            prefix.push(digit_to_char(MID_IDX));
            return Ok(prefix);
        }
        prefix.push(digit_to_char(0));
    }
    Err(Error::InvalidOrderBounds {
        lower: None,
        upper: Some(upper.to_string()),
    })
}

fn midpoint(lower: &str, upper: &str) -> Result<String> {
    let l_bytes = lower.as_bytes();
    let u_bytes = upper.as_bytes();
    let mut out = String::new();
    let mut i = 0;

    loop {
        let l_digit = if i < l_bytes.len() {
            char_to_digit(l_bytes[i])?
        } else {
            0
        };
        let u_digit = if i < u_bytes.len() {
            char_to_digit(u_bytes[i])?
        } else {
            BASE
        };

        if u_digit - l_digit > 1 {
            let mid = l_digit + (u_digit - l_digit) / 2;
            out.push(digit_to_char(mid));
            return Ok(out);
        }

        out.push(digit_to_char(l_digit));
        i += 1;
        if u_digit > l_digit {
            let mut rest = out;
            let mut j = i;
            loop {
                let ld = if j < l_bytes.len() {
                    char_to_digit(l_bytes[j])?
                } else {
                    0
                };
                if BASE - ld > 1 {
                    let mid = ld + (BASE - ld) / 2;
                    rest.push(digit_to_char(mid));
                    return Ok(rest);
                }
                rest.push(digit_to_char(ld));
                j += 1;
            }
        }
    }
}
