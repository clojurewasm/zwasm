package main

import "unsafe"

// Simulates real workload: allocate struct array, filter active records, sum values.
// Param: record count (array size).
// Returns: sum of active record values.
//
// Record layout: [id int32 (4), value int32 (4), active int32 (4)] = 12 bytes.
// Max param: ~170000 (fits in 2MB scratch starting at offset 1024).

const rwScratch = 1024
const recordSize = 12

//export real_work
func real_work(n int32) int32 {
	base := unsafe.Pointer(uintptr(rwScratch))

	// Build records
	for i := int32(0); i < n; i++ {
		recPtr := unsafe.Add(base, uintptr(i)*recordSize)
		*(*int32)(recPtr) = i
		*(*int32)(unsafe.Add(recPtr, 4)) = i * 2
		active := int32(0)
		if i%3 == 0 {
			active = 1
		}
		*(*int32)(unsafe.Add(recPtr, 8)) = active
	}

	// Filter active + sum values
	var sum int32
	for i := int32(0); i < n; i++ {
		recPtr := unsafe.Add(base, uintptr(i)*recordSize)
		active := *(*int32)(unsafe.Add(recPtr, 8))
		if active != 0 {
			sum += *(*int32)(unsafe.Add(recPtr, 4))
		}
	}
	return sum
}

func main() {}
