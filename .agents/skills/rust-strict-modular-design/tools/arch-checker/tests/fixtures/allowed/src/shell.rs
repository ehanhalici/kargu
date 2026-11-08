use std::fs;

pub struct Report(Vec<u8>);

pub fn load(name: &std::path::Path) -> std::io::Result<Report> {
    fs::read(name).map(Report)
}
