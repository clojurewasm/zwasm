package main

// Integer-to-string conversion loop.
// Param: iteration count.
// Returns: sum of digit counts for all integers 0..n-1.
//
// Manual itoa avoids pulling in strconv (which bloats TinyGo wasm).

//export string_ops
func string_ops(n int32) int32 {
	var total int32
	for i := int32(0); i < n; i++ {
		total += digitCount(i)
	}
	return total
}

func digitCount(v int32) int32 {
	if v == 0 {
		return 1
	}
	count := int32(0)
	if v < 0 {
		v = -v
		count = 1 // minus sign
	}
	for v > 0 {
		v /= 10
		count++
	}
	return count
}

func main() {}
