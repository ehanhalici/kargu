//! Live circuit leases are logical, owner/authority-bound, and drain-aware.

use super::*;
struct Fixture {
    peer: Peer,
    scope: Value,
    budget: Value,
    params: Value,
    server: Server,
    requests: mpsc::Receiver<Vec<u8>>,
}
impl Fixture {
    fn new(
        replies: Vec<(u16, String, String)>,
        retries: u64,
        cooldown: u64,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let (url, server, requests) = server(replies)?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let budget = open(&mut peer, &scope, json!({}), None)?;
        let params = json!({"scope":scope,"budget":{"budget_id":budget,"kind":"normal_request"},
            "retry":{"policy":{"retry_max":retries,"backoff_base_ms":1,"backoff_cap_ms":1},"observer":"editor",
                "circuit":{"failure_threshold":1,"cooldown_ms":cooldown}},
            "arguments":{"method":"post","url":url,"provider":"fixture","body":"{}",
                "headers":{"Authorization":"Bearer synthetic-captured"},"stream":false,
                "timeouts":{"connect_ms":500,"first_byte_ms":3000,"idle_ms":null,"deadline_ms":3000}}});
        Ok(Self {
            peer,
            scope,
            budget,
            params,
            server,
            requests,
        })
    }
    fn send(&mut self, id: &str) -> TestResult {
        self.peer
            .send(json!({"jsonrpc":"2.0","id":id,"method":"api/request","params":self.params}))
    }
    fn terminal(&self, id: &str) -> Result<Value, Box<dyn std::error::Error>> {
        loop {
            let reply = self.peer.read()?;
            assert_ne!(
                reply["method"], "editor/api_retry",
                "unexpected observer: {reply}"
            );
            if reply["id"] == id {
                return Ok(reply);
            }
        }
    }
    fn acknowledge(&mut self, observation: &Value) -> TestResult {
        self.peer
            .send(json!({"jsonrpc":"2.0","id":observation["id"],"result":{"accepted":true}}))
    }
    fn rpc(&mut self, method: &str, fields: Value) -> Result<Value, Box<dyn std::error::Error>> {
        let mut params = fields;
        params
            .as_object_mut()
            .ok_or("RPC fixture fields")?
            .insert("scope".into(), self.scope.clone());
        self.peer
            .send(json!({"jsonrpc":"2.0","id":"rpc","method":method,"params":params}))?;
        let reply = self.peer.read()?;
        assert_eq!(reply["id"], "rpc");
        Ok(reply)
    }
    fn wait_retired(&mut self) -> TestResult {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let reply = self.rpc("api/budget/snapshot", json!({"budget_id":self.budget}))?;
            if reply["result"]["outstanding"] == 0 {
                return Ok(());
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    fn trip(&mut self) -> Result<Value, Box<dyn std::error::Error>> {
        self.send("trip")?;
        let observation = observer(&self.peer)?;
        self.acknowledge(&observation)?;
        let reply = self.terminal("trip")?;
        assert_eq!(reply["result"]["failure"]["status"], 503);
        assert_eq!(reply["result"]["circuit"]["failures"], 1);
        Ok(reply["result"]["circuit"]["circuit_id"].clone())
    }
    fn finish(self) -> TestResult {
        no_extra_socket(self.server)
    }
}

#[test]
fn sole_probe_spans_real_backoff_and_observer_without_an_extra_charge() -> TestResult {
    let mut fixture = Fixture::new(
        vec![
            transient(""),
            transient(""),
            transient("Retry-After: 1\r\n"),
            success(),
        ],
        1,
        10,
    )?;
    fixture.trip()?;
    std::thread::sleep(Duration::from_millis(20));
    fixture.send("probe")?;
    for _ in 0..3 {
        fixture.requests.recv_timeout(Duration::from_secs(2))?;
    }
    fixture.wait_retired()?;
    fixture.send("blocked-backoff")?;
    assert_eq!(
        fixture.peer.read()?["error"]["data"]["status"],
        "circuit_open"
    );
    let observation = observer(&fixture.peer)?;
    fixture.send("blocked-observer")?;
    assert_eq!(
        fixture.peer.read()?["error"]["data"]["status"],
        "circuit_open"
    );
    let budget = fixture.rpc("api/budget/snapshot", json!({"budget_id":fixture.budget}))?;
    assert_eq!(budget["result"]["requests_spent"], 3);
    let status = fixture.rpc("api/circuit/snapshot", json!({}))?;
    assert_eq!(status["result"]["circuits"][0]["state"], "half_open");
    assert_eq!(status["result"]["circuits"][0]["probe_inflight"], true);
    fixture.acknowledge(&observation)?;
    let reply = fixture.terminal("probe")?;
    assert_eq!(reply["result"]["circuit"]["state"], "closed");
    assert_eq!(reply["result"]["circuit"]["failures"], 0);
    assert_eq!(reply["result"]["budget"]["requests_spent"], 4);
    fixture.finish()
}

#[test]
fn reset_during_observation_invalidates_late_failure_without_releasing_its_slot() -> TestResult {
    let mut fixture = Fixture::new(
        vec![
            transient(""),
            transient(""),
            transient(""),
            success(),
            transient(""),
        ],
        1,
        10,
    )?;
    let id = fixture.trip()?;
    std::thread::sleep(Duration::from_millis(20));
    fixture.send("old-probe")?;
    let observation = observer(&fixture.peer)?;
    let reset = fixture.rpc("api/circuit/reset", json!({"circuit_id":id}))?;
    assert_eq!(reset["result"]["circuits"][0]["state"], "closed");
    fixture.send("new-regular")?;
    assert_eq!(
        fixture.terminal("new-regular")?["result"]["circuit"]["failures"],
        0
    );
    fixture.acknowledge(&observation)?;
    let reply = fixture.terminal("old-probe")?;
    assert_eq!(reply["result"]["failure"]["status"], 503);
    assert_eq!(reply["result"]["circuit"]["state"], "closed");
    assert_eq!(reply["result"]["circuit"]["failures"], 0);
    assert_eq!(reply["result"]["budget"]["requests_spent"], 5);
    fixture.finish()
}

#[test]
fn canceled_probe_is_neutral_and_can_be_reacquired_after_actual_join() -> TestResult {
    let mut fixture = Fixture::new(
        vec![transient(""), transient(""), transient(""), success()],
        1,
        10,
    )?;
    fixture.trip()?;
    std::thread::sleep(Duration::from_millis(20));
    fixture.send("canceled-probe")?;
    let observation = observer(&fixture.peer)?;
    fixture.peer.send(json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"request_id":"canceled-probe","scope":fixture.peer.epoch}}))?;
    let reply = fixture.terminal("canceled-probe")?;
    assert_eq!(reply["result"]["failure"]["code"], "cancelled");
    assert_eq!(reply["result"]["circuit"]["state"], "half_open");
    assert_eq!(reply["result"]["circuit"]["failures"], 1);
    assert_eq!(reply["result"]["circuit"]["probe_inflight"], false);
    fixture.acknowledge(&observation)?; // Late ACK is inert.
    fixture.send("replacement-probe")?;
    assert_eq!(
        fixture.terminal("replacement-probe")?["result"]["circuit"]["state"],
        "closed"
    );
    fixture.finish()
}

#[test]
fn same_model_namespace_shares_circuit_but_auth_endpoint_and_application_do_not() -> TestResult {
    let mut fixture = Fixture::new(
        vec![transient(""), success(), success(), success()],
        0,
        30_000,
    )?;
    fixture.send("trip")?;
    let tripped = fixture.terminal("trip")?;
    let original_id = tripped["result"]["circuit"]["circuit_id"].clone();
    fixture.params["arguments"]["body"] = json!("{\"model\":\"different-model\"}");
    fixture.send("same-authority")?;
    assert_eq!(
        fixture.peer.read()?["error"]["data"]["status"],
        "circuit_open"
    );
    fixture.params["arguments"]["headers"]["Authorization"] = json!("Bearer different-synthetic");
    fixture.send("other-auth")?;
    let reply = fixture.terminal("other-auth")?;
    assert_eq!(reply["result"]["circuit"]["state"], "closed");
    assert_ne!(reply["result"]["circuit"]["circuit_id"], original_id);
    fixture.params["arguments"]["headers"]["Authorization"] = json!("Bearer synthetic-captured");
    let other = fixture.peer.scope()?;
    let other_budget = open(&mut fixture.peer, &other, json!({}), None)?;
    fixture.params["scope"] = other;
    fixture.params["budget"]["budget_id"] = other_budget;
    fixture.send("other-app")?;
    assert_eq!(
        fixture.terminal("other-app")?["result"]["circuit"]["state"],
        "closed"
    );
    fixture.params["scope"] = fixture.scope.clone();
    fixture.params["budget"]["budget_id"] = fixture.budget.clone();
    let endpoint = fixture.params["arguments"]["url"]
        .as_str()
        .ok_or("URL")?
        .to_owned();
    fixture.params["arguments"]["url"] =
        json!(format!("{endpoint}?tenant=synthetic-private-query"));
    fixture.send("other-endpoint")?;
    let reply = fixture.terminal("other-endpoint")?;
    assert_eq!(reply["result"]["circuit"]["state"], "closed");
    assert!(!reply.to_string().contains("synthetic-private-query"));
    fixture.finish()
}

#[test]
fn foreign_snapshot_reset_and_client_failures_cannot_heal_or_trip_another_circuit() -> TestResult {
    let mut fixture = Fixture::new(
        vec![(401, String::new(), String::new()), transient("")],
        0,
        30_000,
    )?;
    fixture.send("client")?;
    let client = fixture.terminal("client")?;
    assert_eq!(client["result"]["circuit"]["failures"], 0);
    fixture.send("trip")?;
    let tripped = fixture.terminal("trip")?;
    let id = tripped["result"]["circuit"]["circuit_id"].clone();
    let foreign = fixture.peer.scope()?;
    for method in ["api/circuit/snapshot", "api/circuit/reset"] {
        fixture.peer.send(json!({"jsonrpc":"2.0","id":"foreign","method":method,"params":{"scope":foreign,"circuit_id":id}}))?;
        assert_eq!(
            fixture.peer.read()?["error"]["data"]["status"],
            "stale_owner"
        );
    }
    let status = fixture.rpc("api/circuit/snapshot", json!({"circuit_id":id}))?;
    assert_eq!(status["result"]["circuits"][0]["state"], "open");
    assert_eq!(status["result"]["circuits"][0]["failures"], 1);
    fixture.finish()
}

#[test]
fn malformed_model_response_cannot_mark_an_open_probe_healthy() -> TestResult {
    let mut fixture = Fixture::new(
        vec![transient(""), (200, String::new(), "{}".into()), success()],
        0,
        10,
    )?;
    fixture.send("trip")?;
    fixture.terminal("trip")?;
    std::thread::sleep(Duration::from_millis(20));
    fixture.send("invalid-probe")?;
    let reply = fixture.terminal("invalid-probe")?;
    assert_eq!(reply["result"]["failure"]["code"], "protocol_error");
    assert_eq!(reply["result"]["circuit"]["state"], "half_open");
    assert_eq!(reply["result"]["circuit"]["failures"], 1);
    fixture.send("valid-probe")?;
    assert_eq!(
        fixture.terminal("valid-probe")?["result"]["circuit"]["state"],
        "closed"
    );
    fixture.finish()
}
