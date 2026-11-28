use chrono::{Datelike, Duration, Local, NaiveDate};

use crate::error::{Error, Result};

pub fn resolve_journal_date(date: Option<&str>) -> Result<(i32, String)> {
    match date {
        Some(raw) => parse_iso_date(raw),
        None => Ok(today_local()),
    }
}

pub fn local_time_of_day() -> String {
    Local::now().format("%H:%M").to_string()
}

pub fn shift_journal_date(date: Option<&str>, delta_days: i32) -> Result<String> {
    let base = match date {
        Some(raw) => {
            let (day, _) = parse_iso_date(raw)?;
            let y = day / 10_000;
            let m = ((day / 100) % 100) as u32;
            let d = (day % 100) as u32;
            NaiveDate::from_ymd_opt(y, m, d).ok_or_else(|| Error::InvalidDate(raw.to_string()))?
        }
        None => Local::now().date_naive(),
    };
    let shifted = base + Duration::days(i64::from(delta_days));
    Ok(format!(
        "{:04}-{:02}-{:02}",
        shifted.year(),
        shifted.month(),
        shifted.day()
    ))
}

pub fn format_journal_day(day: i32) -> String {
    let year = day / 10_000;
    let month = (day / 100) % 100;
    let date = day % 100;
    format!("{year:04}-{month:02}-{date:02}")
}

pub fn parse_iso_date(raw: &str) -> Result<(i32, String)> {
    let parts: Vec<&str> = raw.trim().split('-').collect();
    if parts.len() != 3 || parts[0].len() != 4 || parts[1].len() != 2 || parts[2].len() != 2 {
        return Err(Error::InvalidDate(raw.to_string()));
    }
    let year: i32 = parts[0]
        .parse()
        .map_err(|_| Error::InvalidDate(raw.to_string()))?;
    let month: u32 = parts[1]
        .parse()
        .map_err(|_| Error::InvalidDate(raw.to_string()))?;
    let day: u32 = parts[2]
        .parse()
        .map_err(|_| Error::InvalidDate(raw.to_string()))?;
    if !(1..=12).contains(&month) || !(1..=days_in_month(year, month)).contains(&day) {
        return Err(Error::InvalidDate(raw.to_string()));
    }
    let journal_day = year * 10_000 + (month as i32) * 100 + (day as i32);
    Ok((journal_day, format!("{year:04}-{month:02}-{day:02}")))
}

fn today_local() -> (i32, String) {
    let today = Local::now().date_naive();
    let year = today.year();
    let month = today.month();
    let day = today.day();
    let journal_day = year * 10_000 + (month as i32) * 100 + (day as i32);
    (journal_day, format!("{year:04}-{month:02}-{day:02}"))
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
                29
            } else {
                28
            }
        }
        _ => 0,
    }
}
