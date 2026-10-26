//! Incremental strict UTF-8 and BOM UTF-16; no lossy reinterpretation of invalid text.

use crate::error::CoreError;
use zeroize::Zeroizing;

#[derive(Default)]
enum Encoding {
    #[default]
    Undecided,
    Utf8,
    Utf16Le,
    Utf16Be,
}
#[derive(Default)]
pub(super) struct Decoder {
    encoding: Encoding,
    carry: Zeroizing<Vec<u8>>,
}
impl Decoder {
    pub(super) fn decode(
        &mut self,
        bytes: &[u8],
        complete: bool,
    ) -> Result<Zeroizing<String>, CoreError> {
        self.carry.extend_from_slice(bytes);
        if matches!(self.encoding, Encoding::Undecided) {
            if self.carry.len() < 3 && !complete {
                return Ok(Zeroizing::new(String::new()));
            }
            let bom = if self.carry.starts_with(&[0xff, 0xfe]) {
                self.encoding = Encoding::Utf16Le;
                2
            } else if self.carry.starts_with(&[0xfe, 0xff]) {
                self.encoding = Encoding::Utf16Be;
                2
            } else {
                self.encoding = Encoding::Utf8;
                if self.carry.starts_with(&[0xef, 0xbb, 0xbf]) {
                    3
                } else {
                    0
                }
            };
            self.carry.drain(..bom);
        }
        let mut output = Zeroizing::new(String::new());
        let consumed = match self.encoding {
            Encoding::Utf8 => {
                let end = match std::str::from_utf8(&self.carry) {
                    Ok(_) => self.carry.len(),
                    Err(error) if error.error_len().is_none() && !complete => error.valid_up_to(),
                    Err(_) => {
                        return Err(CoreError::InvalidValue {
                            field: "FileEncoding",
                        });
                    }
                };
                output.push_str(
                    std::str::from_utf8(self.carry.get(..end).ok_or(CoreError::Limit)?).map_err(
                        |_| CoreError::InvalidValue {
                            field: "FileEncoding",
                        },
                    )?,
                );
                end
            }
            Encoding::Utf16Le | Encoding::Utf16Be => {
                let mut units = Zeroizing::new(
                    self.carry
                        .chunks_exact(2)
                        .map(|pair| {
                            let data = [
                                pair.first().copied().unwrap_or_default(),
                                pair.get(1).copied().unwrap_or_default(),
                            ];
                            if matches!(self.encoding, Encoding::Utf16Le) {
                                u16::from_le_bytes(data)
                            } else {
                                u16::from_be_bytes(data)
                            }
                        })
                        .collect::<Vec<_>>(),
                );
                if !complete
                    && units
                        .last()
                        .is_some_and(|unit| (0xd800..=0xdbff).contains(unit))
                {
                    units.pop();
                }
                let consumed = units.len().saturating_mul(2);
                if complete && consumed != self.carry.len() {
                    return Err(CoreError::InvalidValue {
                        field: "FileEncoding",
                    });
                }
                for character in char::decode_utf16(units.iter().copied()) {
                    output.push(character.map_err(|_| CoreError::InvalidValue {
                        field: "FileEncoding",
                    })?);
                }
                consumed
            }
            Encoding::Undecided => {
                return Err(CoreError::InvalidValue {
                    field: "FileEncoding",
                });
            }
        };
        self.carry.drain(..consumed);
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_utf8_and_utf16_chunk_boundary_preserves_scalar_values() -> Result<(), CoreError> {
        let text = "α😀\r\nsecond\n";
        let mut encodings = vec![text.as_bytes().to_vec()];
        for little in [false, true] {
            let mut bytes = if little {
                vec![0xff, 0xfe]
            } else {
                vec![0xfe, 0xff]
            };
            for unit in text.encode_utf16() {
                bytes.extend(if little {
                    unit.to_le_bytes()
                } else {
                    unit.to_be_bytes()
                });
            }
            encodings.push(bytes);
        }
        for bytes in encodings {
            for width in 1..=bytes.len() {
                let mut decoder = Decoder::default();
                let mut result = String::new();
                let mut chunks = bytes.chunks(width).peekable();
                while let Some(chunk) = chunks.next() {
                    result.push_str(&decoder.decode(chunk, chunks.peek().is_none())?);
                }
                assert_eq!(result, text);
            }
        }
        Ok(())
    }
}
