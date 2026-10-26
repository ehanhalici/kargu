use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

type TestResult = Result<(), Box<dyn std::error::Error>>;

pub(super) struct Peer {
    child: Child,
    pub(super) input: Option<ChildStdin>,
    output: Receiver<String>,
    pub(super) epoch: String,
}

impl Peer {
    pub(super) fn start() -> Result<Self, Box<dyn std::error::Error>> {
        Self::start_with_path(None)
    }
    pub(super) fn start_with_path(
        path: Option<&std::path::Path>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        Self::start_with_path_and_environment(path, &[])
    }
    pub(super) fn start_with_path_and_environment(
        path: Option<&std::path::Path>,
        environment: &[(&str, &std::ffi::OsStr)],
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let mut command = Command::new(env!("CARGO_BIN_EXE_kargu-core"));
        command
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1");
        command.envs(environment.iter().copied());
        if let Some(path) = path {
            command.env("PATH", path);
        }
        let mut child = command
            .process_group(0)
            .arg("--stdio")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let input = child.stdin.take().ok_or("missing stdin")?;
        let stdout = child.stdout.take().ok_or("missing stdout")?;
        let (tx, output) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                match line {
                    Ok(line) => {
                        if tx.send(line).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });
        Ok(Self {
            child,
            input: Some(input),
            output,
            epoch: String::new(),
        })
    }
    pub(super) fn raw(&mut self, bytes: &[u8]) -> TestResult {
        let input = self.input.as_mut().ok_or("closed stdin")?;
        input.write_all(bytes)?;
        input.flush()?;
        Ok(())
    }
    pub(super) fn send(&mut self, value: Value) -> TestResult {
        self.raw(format!("{value}\n").as_bytes())
    }
    pub(super) fn read(&self) -> Result<Value, Box<dyn std::error::Error>> {
        // Production cleanup includes a five-second TERM grace and pipe/reap drain.
        let line = self.output.recv_timeout(Duration::from_secs(12))?;
        Ok(serde_json::from_str(&line)?)
    }
    pub(super) fn initialize(&mut self) -> TestResult {
        self.send(json!({"jsonrpc":"2.0","id":"e:init","method":"initialize",
            "params":{"protocol_major":1,"protocol_minor":0,"client_version":"pipe-test",
            "capabilities":[],"limits":{"max_frame_bytes":1048576}}}))?;
        let initialized = self.read()?;
        self.epoch = initialized["result"]["connection_epoch"]
            .as_str()
            .ok_or("epoch missing")?
            .to_owned();
        self.send(json!({"jsonrpc":"2.0","method":"initialized"}))
    }
    pub(super) fn scope(&mut self) -> Result<Value, Box<dyn std::error::Error>> {
        self.send(json!({"jsonrpc":"2.0","id":1,"method":"application/create"}))?;
        let app = self.read()?["result"].clone();
        self.send(json!({"jsonrpc":"2.0","id":2,"method":"session/create","params":app}))?;
        Ok(self.read()?["result"].clone())
    }
    pub(super) fn wait(&mut self) -> Result<bool, Box<dyn std::error::Error>> {
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            if let Some(status) = self.child.try_wait()? {
                return Ok(status.success());
            }
            if Instant::now() >= deadline {
                return Err("child failed to exit".into());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        // EOF lets the real supervisor TERM/KILL and reap its own child groups.
        // Killing the core first would strand those independent PGID leaders.
        self.input.take();
        let deadline = Instant::now() + Duration::from_secs(12);
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(5))
                }
                _ => break,
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
