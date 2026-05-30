#![no_std]
#![no_main]
#[no_mangle]
pub extern "C" fn test() -> i32 {
    let mut acc: i32 = 0;
    let mut i: i32 = 0;
    while i < 10 {
        acc += i;
        i += 1;
    }
    acc
}
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
