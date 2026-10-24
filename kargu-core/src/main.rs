//! Stdio entry point. stdout is reserved exclusively for wire messages.

#![forbid(unsafe_code)]

#[tokio::main]
async fn main() -> std::process::ExitCode {
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() != Some("--stdio") || args.next().is_some() {
        eprintln!("Usage: kargu-core --stdio");
        return std::process::ExitCode::from(2);
    }
    match kargu_core::ipc::serve(tokio::io::stdin(), tokio::io::stdout()).await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(_) => {
            // Never include a raw frame, params, or OS/provider error body.
            eprintln!("kargu-core: transport closed with an error");
            std::process::ExitCode::FAILURE
        }
    }
}
