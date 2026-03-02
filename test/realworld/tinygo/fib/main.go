// fib — TinyGo WASI: recursive fibonacci
package main

import "fmt"

func fib(n int) int {
	if n <= 1 {
		return n
	}
	return fib(n-1) + fib(n-2)
}

func main() {
	result := fib(30)
	fmt.Printf("fib(30) = %d\n", result)
}
