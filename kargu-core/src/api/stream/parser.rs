use super::{ApiError, StreamLimits};
use serde_json::Value;

pub(super) enum Event {
    Done,
    Data(Value),
}

pub(super) struct Parser {
    limits: StreamLimits,
    line: Vec<u8>,
    data: String,
    has_data: bool,
    event_error: bool,
    total: usize,
}
impl Parser {
    pub fn new(limits: StreamLimits) -> Self {
        Self {
            limits,
            line: Vec::new(),
            data: String::new(),
            has_data: false,
            event_error: false,
            total: 0,
        }
    }
    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<Event>, ApiError> {
        self.total = self.total.checked_add(bytes.len()).ok_or(ApiError::Limit)?;
        if self.total > self.limits.raw() {
            return Err(ApiError::Limit);
        }
        let mut events = Vec::new();
        for byte in bytes {
            if *byte == b'\n' {
                if let Some(event) = self.take_line()? {
                    events.push(event);
                }
            } else {
                if self.line.len() >= self.limits.line() {
                    return Err(ApiError::Limit);
                }
                self.line.push(*byte);
            }
        }
        Ok(events)
    }
    fn take_line(&mut self) -> Result<Option<Event>, ApiError> {
        let bytes = std::mem::take(&mut self.line);
        let text = std::str::from_utf8(&bytes).map_err(|_| ApiError::Protocol)?;
        let text = text.strip_suffix('\r').unwrap_or(text);
        if text.is_empty() {
            return self.dispatch();
        }
        if text.starts_with(':') {
            return Ok(None);
        }
        let (field, value) = text.split_once(':').unwrap_or((text, ""));
        let value = value.strip_prefix(' ').unwrap_or(value);
        match field {
            "data" => {
                let size = self
                    .data
                    .len()
                    .saturating_add(value.len())
                    .saturating_add(usize::from(self.has_data));
                if size > self.limits.event() {
                    return Err(ApiError::Limit);
                }
                if self.has_data {
                    self.data.push('\n');
                }
                self.has_data = true;
                self.data.push_str(value);
            }
            "event" => self.event_error = value == "error",
            _ => {}
        }
        Ok(None)
    }
    fn dispatch(&mut self) -> Result<Option<Event>, ApiError> {
        let error = std::mem::take(&mut self.event_error);
        if !std::mem::take(&mut self.has_data) {
            return Ok(None);
        }
        let data = std::mem::take(&mut self.data);
        if data.trim() == "[DONE]" {
            return Ok(Some(Event::Done));
        }
        let mut value: Value = serde_json::from_str(&data).map_err(|_| ApiError::Protocol)?;
        if !value.is_object() {
            return Err(ApiError::Protocol);
        }
        if error {
            value = serde_json::json!({"error":true});
        }
        Ok(Some(Event::Data(value)))
    }
    pub fn finish(&mut self) -> Result<Vec<Event>, ApiError> {
        let mut events = Vec::new();
        if !self.line.is_empty()
            && let Some(event) = self.take_line()?
        {
            events.push(event);
        }
        if let Some(event) = self.dispatch()? {
            events.push(event);
        }
        Ok(events)
    }
}
