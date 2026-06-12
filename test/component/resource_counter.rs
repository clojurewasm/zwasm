wit_bindgen::generate!({ path: "wit", world: "resource-test" });

use exports::zwasm::restest::counter_api::{Guest, GuestCounter};
use std::cell::Cell;

struct Component;

struct Counter {
    value: Cell<u32>,
}

impl GuestCounter for Counter {
    fn new(start: u32) -> Self {
        Counter { value: Cell::new(start) }
    }
    fn increment(&self) -> u32 {
        let v = self.value.get() + 1;
        self.value.set(v);
        v
    }
    fn get(&self) -> u32 {
        self.value.get()
    }
}

impl Guest for Component {
    type Counter = Counter;
}

export!(Component);
