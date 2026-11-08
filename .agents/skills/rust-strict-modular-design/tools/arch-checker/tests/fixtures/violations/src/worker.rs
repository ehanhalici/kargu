pub fn read(name: &str) -> std::io::Result<Vec<u8>> {
    std::fs::read(name)
}
