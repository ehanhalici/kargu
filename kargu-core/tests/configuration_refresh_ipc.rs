//! Rust orders config discovery, read, parse and staging; defaults never supersede.
mod support;
use serde_json::{Value, json};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

struct Client {
    peer: Peer,
    scope: Value,
    sequence: u64,
}
impl Client {
    fn new() -> Result<Self, Box<dyn std::error::Error>> {
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        Ok(Self {
            peer,
            scope,
            sequence: 0,
        })
    }
    fn call(
        &mut self,
        method: &str,
        arguments: Value,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        self.sequence += 1;
        let id = format!("config:{}", self.sequence);
        self.peer
            .send(json!({"jsonrpc":"2.0","id":id,"method":method,
            "params":{"scope":self.scope,"arguments":arguments}}))?;
        loop {
            let value = self.peer.read()?;
            if value["id"] == id {
                return Ok(value);
            }
        }
    }
    fn refresh(&mut self, arguments: Value) -> Result<Value, Box<dyn std::error::Error>> {
        let mut arguments = arguments;
        let object = arguments.as_object_mut().ok_or("arguments")?;
        object.insert("registry".into(), json!([]));
        object.insert("timeout_ms".into(), json!(2000));
        self.call("configuration/refresh", arguments)
    }
    fn commit(&mut self, staged: &Value) -> Result<Value, Box<dyn std::error::Error>> {
        self.call(
            "configuration/commit",
            json!({"capture_id":staged["result"]["capture_id"],
                "context":{"environment":{},"registry":[]}}),
        )
    }
}

#[test]
fn native_precedence_reads_xdg_before_the_emacs_directory() -> TestResult {
    let dir = tempfile::tempdir()?;
    let xdg = dir.path().join("xdg");
    let emacs = dir.path().join("emacs");
    std::fs::create_dir_all(xdg.join("kargu"))?;
    std::fs::create_dir_all(&emacs)?;
    std::fs::write(xdg.join("kargu/config.toml"), "provider='xdg-first'\n")?;
    std::fs::write(emacs.join("kargu.toml"), "provider='emacs-second'\n")?;
    let mut client = Client::new()?;
    let staged = client.refresh(json!({"locations":{
        "home":dir.path(),"xdg_config_home":xdg,"user_emacs_directory":emacs}}))?;
    assert_eq!(staged["result"]["status"], "prepared", "{staged}");
    assert_eq!(
        staged["result"]["path"],
        json!(xdg.join("kargu/config.toml"))
    );
    assert!(!staged.to_string().contains("xdg-first"));
    let committed = client.commit(&staged)?;
    assert_eq!(
        committed["result"]["config"]["provider"], "xdg-first",
        "{committed}"
    );

    // A relative XDG value is ignored; HOME/.config is used instead.
    let home_config = dir.path().join(".config/kargu");
    std::fs::create_dir_all(&home_config)?;
    std::fs::write(home_config.join("config.toml"), "provider='home-config'\n")?;
    let staged = client.refresh(json!({"locations":{
        "home":dir.path(),"xdg_config_home":"relative","user_emacs_directory":emacs}}))?;
    assert_eq!(
        staged["result"]["path"],
        json!(home_config.join("config.toml"))
    );
    let committed = client.commit(&staged)?;
    assert_eq!(committed["result"]["config"]["provider"], "home-config");
    assert!(
        client
            .refresh(json!({"locations":{"home":null,"xdg_config_home":null,
            "user_emacs_directory":emacs}}))?
            .get("error")
            .is_some()
    );
    Ok(())
}

#[test]
fn defaults_bootstrap_never_overwrites_and_a_real_refresh_supersedes_it() -> TestResult {
    let dir = tempfile::tempdir()?;
    let file = dir.path().join("config.toml");
    std::fs::write(&file, "provider='real'\n")?;
    let mut client = Client::new()?;
    let defaults =
        client.refresh(json!({"paths":[dir.path().join("absent.toml")],"defaults_only":true}))?;
    assert_eq!(defaults["result"]["status"], "prepared", "{defaults}");
    assert_eq!(defaults["result"]["absent"], true);
    // A real refresh staged after the bootstrap wins; the bootstrap ticket is stale.
    let real = client.refresh(json!({"paths":[file]}))?;
    assert_eq!(real["result"]["status"], "prepared", "{real}");
    let stale = client.commit(&defaults)?;
    assert_eq!(
        stale["error"]["data"]["status"], "stale_configuration",
        "{stale}"
    );
    let committed = client.commit(&real)?;
    assert_eq!(committed["result"]["config"]["provider"], "real");
    // After a publication, defaults only observe.
    let observed =
        client.refresh(json!({"paths":[dir.path().join("absent.toml")],"defaults_only":true}))?;
    assert_eq!(observed["result"]["status"], "observed", "{observed}");
    let snapshot = client.call("configuration/snapshot", json!({}))?;
    assert_eq!(snapshot["result"]["config"]["provider"], "real");
    Ok(())
}

#[test]
fn invalid_source_reports_its_line_without_staging() -> TestResult {
    let dir = tempfile::tempdir()?;
    let file = dir.path().join("config.toml");
    std::fs::write(&file, "provider='ok'\n[[broken\n")?;
    let mut client = Client::new()?;
    let invalid = client.refresh(json!({"paths":[file]}))?;
    assert_eq!(invalid["result"]["status"], "invalid", "{invalid}");
    assert_eq!(invalid["result"]["line"], 2);
    assert!(invalid["result"].get("capture_id").is_none());
    // The failed read released its claim, so a bootstrap may still publish defaults.
    let defaults =
        client.refresh(json!({"paths":[dir.path().join("absent.toml")],"defaults_only":true}))?;
    assert_eq!(defaults["result"]["status"], "prepared", "{defaults}");
    Ok(())
}
