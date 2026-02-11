package main

import "unsafe"

// Linked list build + traverse using raw linear memory.
// Fixed list size 500, param controls iteration count.
// Returns: total nodes traversed across all iterations.
//
// Each node: [val int32 (4 bytes), next_offset int32 (4 bytes)] = 8 bytes.
// next_offset = 0 means nil (no next node).

const listScratch = 1024
const nodeSize = 8
const listSize = 500

//export list_build
func list_build(iters int32) int32 {
	base := unsafe.Pointer(uintptr(listScratch))
	var total int32

	for iter := int32(0); iter < iters; iter++ {
		var headOff int32 // 0 = nil

		// Build linked list: prepend each node
		for i := int32(0); i < listSize; i++ {
			off := (i + 1) * nodeSize
			nodePtr := unsafe.Add(base, uintptr(off))
			*(*int32)(nodePtr) = i
			*(*int32)(unsafe.Add(nodePtr, 4)) = headOff
			headOff = off
		}

		// Traverse and count
		count := int32(0)
		cur := headOff
		for cur != 0 {
			nodePtr := unsafe.Add(base, uintptr(cur))
			cur = *(*int32)(unsafe.Add(nodePtr, 4))
			count++
		}
		total += count
	}
	return total
}

func main() {}
