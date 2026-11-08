use std::fs;
pub use crate::edge::*;

pub struct Leaky {
    pub secret: u64,
}

pub struct Wrapper(pub u64);

static COUNTER: std::sync::Mutex<u8> = std::sync::Mutex::new(0);

pub struct Total(u64);

pub fn total(raw: u64) -> Total {
    Total(raw)
}

pub fn announce(total: &Total) {
    let _ = total;
}

pub fn read_clock() -> Total {
    let _ = std::time::SystemTime::now();
    println!("now");
    Total(0)
}

pub fn panicky(value: Option<Total>) -> Total {
    value.unwrap()
}

pub fn not_yet() -> Total {
    todo!()
}

pub fn long(a: Total, b: Total, c: Total) -> Total {
    let _ = a;
    let _ = b;
    let _ = c;
    Total(1)
}

pub fn deep(value: Option<Total>) -> Total {
    match value {
        Some(total) => {
            if total.0 > 1 {
                for _ in 0..1 {}
            }
            total
        }
        None => Total(0),
    }
}

use std as hidden;

pub fn spliced() -> Total {
    include!("edge.rs");
    Total(0)
}

use std::time::Instant;

pub fn started() -> Option<Instant> {
    Some(Instant::now())
}
