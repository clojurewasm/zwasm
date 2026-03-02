// sort — TinyGo WASI: sort 200 random integers
package main

import (
	"fmt"
	"sort"
)

func main() {
	n := 200
	data := make([]int, n)

	// Fill with pseudo-random values using LCG
	x := 12345
	for i := 0; i < n; i++ {
		x = (x*1103515245 + 12345) & 0x7fffffff
		data[i] = x % 100000
	}

	sort.Ints(data)

	// Verify sorted
	sorted := true
	for i := 1; i < n; i++ {
		if data[i] < data[i-1] {
			sorted = false
			break
		}
	}

	fmt.Printf("sorted %d integers: %v\n", n, sorted)
	fmt.Printf("first = %d, last = %d\n", data[0], data[n-1])
}
