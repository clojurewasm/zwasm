//! WASI 0.3 conformance: read the wall + monotonic clocks; exit(0) iff the wall
//! clock returns a value at/after the unix epoch (proves wasi:clocks delivery).
use std::time::{Instant, SystemTime, UNIX_EPOCH};
fn main() {
    let _ = Instant::now(); // monotonic-clock now (must not trap)
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(_) => std::process::exit(0),
        Err(_) => std::process::exit(1),
    }
}
