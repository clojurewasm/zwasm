package main

import "unsafe"

// N-Queens solver via iterative backtracking.
// Param: iteration count (solve N=8 board multiple times).
// Returns: total solutions found across all iterations.
//
// Uses iterative approach with explicit row stack stored in linear memory
// to avoid recursive function calls and array pointer passing.

const nqScratch = 1024
const nqBoardSize = 8

//export nqueens
func nqueens(iters int32) int32 {
	base := unsafe.Pointer(uintptr(nqScratch))
	var total int32

	for iter := int32(0); iter < iters; iter++ {
		solutions := int32(0)
		row := int32(0)

		// Initialize queens to -1
		for i := int32(0); i < nqBoardSize; i++ {
			*(*int32)(unsafe.Add(base, uintptr(i)*4)) = -1
		}

		for row >= 0 {
			qPtr := (*int32)(unsafe.Add(base, uintptr(row)*4))
			*qPtr++

			if *qPtr >= nqBoardSize {
				*qPtr = -1
				row--
				continue
			}

			col := *qPtr
			ok := true
			for r := int32(0); r < row; r++ {
				qr := *(*int32)(unsafe.Add(base, uintptr(r)*4))
				d := qr - col
				if d == 0 || d == r-row || d == row-r {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}

			if row == nqBoardSize-1 {
				solutions++
				continue
			}
			row++
		}
		total += solutions
	}
	return total
}

func main() {}
