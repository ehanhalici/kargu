//! Conservative numeric egress policy, shared by URL and DNS admission.
use crate::error::CoreError;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use url::{Host, Url};
pub(super) struct Target {
    pub url: Url,
    pub host: String,
    pub port: u16,
}
impl TryFrom<Url> for Target {
    type Error = CoreError;
    fn try_from(mut url: Url) -> Result<Self, CoreError> {
        if !matches!(url.scheme(), "http" | "https")
            || !url.username().is_empty()
            || url.password().is_some()
            || url.as_str().len() > super::MAX_URL_BYTES
        {
            return Err(CoreError::Rejected);
        }
        let host = match url.host().ok_or(CoreError::Rejected)? {
            Host::Domain(h) => {
                let h = h.trim_end_matches('.').to_ascii_lowercase();
                if h == "localhost"
                    || h.ends_with(".localhost")
                    || h.ends_with(".local")
                    || h.ends_with(".internal")
                {
                    return Err(CoreError::Rejected);
                }
                h
            }
            Host::Ipv4(a) => {
                if !public(IpAddr::V4(a)) {
                    return Err(CoreError::Rejected);
                }
                a.to_string()
            }
            Host::Ipv6(a) => {
                if !public(IpAddr::V6(a)) {
                    return Err(CoreError::Rejected);
                }
                a.to_string()
            }
        };
        if matches!(url.host(), Some(Host::Domain(_))) {
            url.set_host(Some(&host)).map_err(|_| CoreError::Rejected)?;
        }
        url.set_fragment(None);
        let port = url.port_or_known_default().ok_or(CoreError::Rejected)?;
        Ok(Self { url, host, port })
    }
}
pub(super) fn public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => public_v4(ip),
        IpAddr::V6(ip) => public_v6(ip),
    }
}
fn public_v4(ip: Ipv4Addr) -> bool {
    let n = u32::from(ip);
    ![
        (0x00000000, 8),
        (0x0a000000, 8),
        (0x64400000, 10),
        (0x7f000000, 8),
        (0xa9fe0000, 16),
        (0xac100000, 12),
        (0xc0000000, 24),
        (0xc0000200, 24),
        (0xc0586300, 24),
        (0xc0a80000, 16),
        (0xc6120000, 15),
        (0xc6336400, 24),
        (0xcb007100, 24),
        (0xe0000000, 3),
    ]
    .iter()
    .any(|(prefix, bits)| n >> (32 - bits) == prefix >> (32 - bits))
}
fn public_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return public_v4(v4);
    }
    let n = u128::from(ip);
    if n >> 32 == 0x0064_ff9b_0000_0000_0000_0000 {
        return public_v4(Ipv4Addr::from((n & u128::from(u32::MAX)) as u32));
    }
    n >> 125 == 1
        && ![
            (0x2001u128 << 112, 23),
            (0x20010db8u128 << 96, 32),
            (0x2002u128 << 112, 16),
            (0x3fffu128 << 112, 20),
        ]
        .iter()
        .any(|(p, b)| n >> (128 - b) == p >> (128 - b))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn conservative_ip_policy_covers_mapped_nat64_and_transition_ranges()
    -> Result<(), Box<dyn std::error::Error>> {
        for addr in [
            "0.0.0.0",
            "10.0.0.1",
            "100.64.0.1",
            "100.127.255.255",
            "127.0.0.1",
            "169.254.1.1",
            "172.31.1.1",
            "192.168.0.1",
            "192.0.2.1",
            "198.18.0.1",
            "198.51.100.1",
            "203.0.113.1",
            "224.0.0.1",
            "255.255.255.255",
            "::",
            "::1",
            "0:0:0:0:0:0:0:1",
            "fe80::1",
            "fe90::1",
            "febf::1",
            "fec0::1",
            "fdff::1",
            "ff02::1",
            "0:0:0:0:0:ffff:7f00:1",
            "64:ff9b::127.0.0.1",
            "64:ff9b:1::808:808",
            "fc00::1",
            "2001:db8::1",
            "2001::1",
            "2002::1",
            "3fff::1",
            "::ffff:127.0.0.1",
            "64:ff9b::a00:1",
        ] {
            assert!(!public(addr.parse()?), "{addr}");
        }
        for addr in [
            "8.8.8.8",
            "1.1.1.1",
            "93.184.216.34",
            "100.128.0.1",
            "172.32.0.1",
            "2001:4860:4860::8888",
            "2606:4700:4700::1111",
            "::ffff:8.8.8.8",
            "64:ff9b::808:808",
        ] {
            assert!(public(addr.parse()?), "{addr}");
        }
        for url in [
            "http://localhost./",
            "http://a.local/",
            "http://127.1/",
            "http://2130706433/",
            "http://[::1]/",
            "http://user:secret@example.com/",
            "file:///etc/passwd",
        ] {
            assert!(Target::try_from(Url::parse(url)?).is_err(), "{url}");
        }
        for address in [
            "example.com",
            "127.1",
            "0177.0.0.1",
            "1.2.3.256",
            "1.2.3.-1",
            "::1%lo",
            "fe80::1%25eth0",
            ":::1",
            "1:::",
            "1::2::3",
            "1:2:3:4:5:6:7",
            "1:2:3:4:5:6:7:8:9",
            "::ffff:127.00.0.1",
            "[::1]",
            "::gggg",
            "::10000",
        ] {
            assert!(address.parse::<IpAddr>().is_err(), "{address}");
        }
        for name in [
            "127.example.com",
            "10.example.org",
            "localhostish.example",
            "internal.example",
        ] {
            let target = Target::try_from(Url::parse(&format!("https://{name}./"))?)?;
            assert_eq!(target.host, name);
            assert_eq!(target.url.host_str(), Some(name));
        }
        Ok(())
    }
}
