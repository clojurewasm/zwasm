// hello — TinyGo WASI: stdout, args, env
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Println("Hello from TinyGo/WASI!")
	fmt.Printf("argc = %d\n", len(os.Args))
	for i, arg := range os.Args {
		fmt.Printf("argv[%d] = %s\n", i, arg)
	}

	home := os.Getenv("HOME")
	if home != "" {
		fmt.Printf("HOME = %s\n", home)
	} else {
		fmt.Println("HOME not set")
	}
}
