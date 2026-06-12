package main

import (
	"fmt"
	"os"
)

func main() {
	// 1. mkdir twice — the second must fail with "exist".
	if err := os.Mkdir("/work/dup", 0o755); err != nil {
		fmt.Println("FAIL first-mkdir", err)
		return
	}
	if err := os.Mkdir("/work/dup", 0o755); !os.IsExist(err) {
		fmt.Println("FAIL dup-mkdir want-exist got", err)
		return
	}
	// 2. stat of a missing path must fail with "not exist".
	if _, err := os.Stat("/work/nope"); !os.IsNotExist(err) {
		fmt.Println("FAIL stat-missing want-noent got", err)
		return
	}
	// 3. remove of a missing path must fail.
	if err := os.Remove("/work/nope"); !os.IsNotExist(err) {
		fmt.Println("FAIL remove-missing want-noent got", err)
		return
	}
	// 4. rename from a missing source must fail.
	if err := os.Rename("/work/nope", "/work/x"); err == nil {
		fmt.Println("FAIL rename-missing want-error got nil")
		return
	}
	// 5. reading an empty directory yields zero entries (stream end on
	// the first read-directory-entry call).
	entries, err := os.ReadDir("/work/dup")
	if err != nil || len(entries) != 0 {
		fmt.Println("FAIL readdir-empty", err, len(entries))
		return
	}
	fmt.Println("ERR-OK")
}
