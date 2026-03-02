// json — TinyGo WASI: manual JSON formatting + parsing
package main

import (
	"fmt"
	"strconv"
	"strings"
)

type Person struct {
	Name string
	Age  int
	City string
}

func (p Person) toJSON() string {
	return fmt.Sprintf(`{"name":%q,"age":%d,"city":%q}`, p.Name, p.Age, p.City)
}

func parsePerson(s string) (Person, error) {
	var p Person
	s = strings.TrimPrefix(s, "{")
	s = strings.TrimSuffix(s, "}")
	parts := strings.Split(s, ",")
	for _, part := range parts {
		kv := strings.SplitN(part, ":", 2)
		if len(kv) != 2 {
			continue
		}
		key := strings.Trim(kv[0], `" `)
		val := strings.Trim(kv[1], `" `)
		switch key {
		case "name":
			p.Name = val
		case "age":
			n, err := strconv.Atoi(val)
			if err != nil {
				return p, err
			}
			p.Age = n
		case "city":
			p.City = val
		}
	}
	return p, nil
}

func main() {
	p := Person{Name: "Alice", Age: 30, City: "Tokyo"}
	data := p.toJSON()
	fmt.Printf("json: %s\n", data)

	p2, err := parsePerson(data)
	if err != nil {
		fmt.Printf("parse error: %s\n", err)
		return
	}
	fmt.Printf("name=%s age=%d city=%s\n", p2.Name, p2.Age, p2.City)

	if p.Name == p2.Name && p.Age == p2.Age && p.City == p2.City {
		fmt.Println("roundtrip: OK")
	} else {
		fmt.Println("roundtrip: FAIL")
	}
}
