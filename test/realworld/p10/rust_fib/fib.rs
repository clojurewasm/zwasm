#![no_std]
#![no_main]
// Recursive fib — `#[inline(never)]` keeps it a real call (not folded),
// exercising the wasm call stack + call/return through the JIT.
#[inline(never)]
fn fib(n: i32) -> i32 {
    if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}
#[no_mangle]
pub extern "C" fn test() -> i32 {
    fib(10)
}
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
