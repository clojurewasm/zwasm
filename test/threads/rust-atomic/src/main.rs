use std::sync::atomic::{AtomicI32, Ordering};

static COUNTER: AtomicI32 = AtomicI32::new(0);

fn main() {
    // Test 1: Basic atomic load/store
    COUNTER.store(42, Ordering::SeqCst);
    let val = COUNTER.load(Ordering::SeqCst);
    assert_eq!(val, 42, "atomic load/store failed");

    // Test 2: Atomic add
    COUNTER.store(0, Ordering::SeqCst);
    COUNTER.fetch_add(10, Ordering::SeqCst);
    COUNTER.fetch_add(20, Ordering::SeqCst);
    let val = COUNTER.load(Ordering::SeqCst);
    assert_eq!(val, 30, "atomic add failed");

    // Test 3: Compare-and-swap
    COUNTER.store(100, Ordering::SeqCst);
    let result = COUNTER.compare_exchange(100, 200, Ordering::SeqCst, Ordering::SeqCst);
    assert_eq!(result, Ok(100), "CAS should succeed");
    let val = COUNTER.load(Ordering::SeqCst);
    assert_eq!(val, 200, "CAS value wrong");

    // Test 4: Failed CAS
    let result = COUNTER.compare_exchange(100, 300, Ordering::SeqCst, Ordering::SeqCst);
    assert_eq!(result, Err(200), "CAS should fail");

    println!("All atomic tests passed!");
}
