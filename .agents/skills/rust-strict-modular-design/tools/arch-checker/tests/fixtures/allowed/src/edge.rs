pub fn raw(input: &str) -> String {
    std::fs::read_to_string(input).unwrap_or_default()
}
