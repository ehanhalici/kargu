use std::fmt;

pub struct Total(u64);

impl Total {
    pub fn new(raw: u64) -> Self {
        Self(raw)
    }
    pub fn get(&self) -> u64 {
        self.0
    }
}

impl fmt::Display for Total {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

pub fn classify(total: &Total) -> Option<Total> {
    if total.get() == 0 {
        None
    } else if total.get() == 1 {
        Some(Total::new(1))
    } else {
        Some(Total::new(2))
    }
}

fn private_helper(raw: u64, flag: bool) -> u64 {
    if flag { raw } else { 0 }
}

#[cfg(test)]
mod tests {
    #[test]
    fn may_unwrap_and_print() {
        println!("{}", Some(1).unwrap());
    }
}

use std::time::{Duration, Instant};

pub struct Tally {
    total: Total,
}

impl Tally {
    pub fn bump(&mut self) {
        self.total = Total::new(self.total.get().saturating_add(1));
    }
}

pub fn elapsed(start: Instant, now: Instant) -> Duration {
    now.saturating_duration_since(start)
}

#[cfg(test)]
mod checks;

pub fn pick(total: &Total) -> Total {
    if total.get() > 1 {
        if total.get() > 2 { Total::new(2) } else { Total::new(1) }
    } else {
        Total::new(0)
    }
}
