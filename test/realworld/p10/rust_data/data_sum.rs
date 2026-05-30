#![no_std]
#![no_main]
// Static-data + memory-read codegen: sum a `static [i32; 8]` via indexed
// loads, with `black_box` on the index so rustc CANNOT const-fold it —
// forcing real i32.load (data-segment-backed) + bounds-check codegen.
// 3+1+4+1+5+9+2+6 = 31.
static DATA: [i32; 8] = [3, 1, 4, 1, 5, 9, 2, 6];
#[no_mangle]
pub extern "C" fn test() -> i32 {
    let mut sum: i32 = 0;
    let mut i: usize = 0;
    while i < 8 {
        sum += DATA[core::hint::black_box(i)];
        i += 1;
    }
    sum
}
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
