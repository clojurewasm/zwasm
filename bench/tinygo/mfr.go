package main

import "unsafe"

// Map-filter-reduce: allocate array, square each element,
// filter even values, sum them. Repeated for `iters` iterations.
// Fixed array size 500, param controls iteration count.
// Returns: int32 checksum (low bits of accumulated sum).

const mfrScratch = 1024
const mfrSize = 500

//export mfr
func mfr(iters int32) int32 {
	base := unsafe.Pointer(uintptr(mfrScratch))
	var total int64

	for iter := int32(0); iter < iters; iter++ {
		// Initialize: arr[i] = i (as int64, 8 bytes each)
		for i := int32(0); i < mfrSize; i++ {
			ptr := (*int64)(unsafe.Add(base, uintptr(i)*8))
			*ptr = int64(i)
		}

		// Map: square each element
		for i := int32(0); i < mfrSize; i++ {
			ptr := (*int64)(unsafe.Add(base, uintptr(i)*8))
			v := *ptr
			*ptr = v * v
		}

		// Filter even + reduce (sum)
		var sum int64
		for i := int32(0); i < mfrSize; i++ {
			v := *(*int64)(unsafe.Add(base, uintptr(i)*8))
			if v%2 == 0 {
				sum += v
			}
		}
		total += sum
	}
	return int32(total & 0x7FFFFFFF)
}

func main() {}
