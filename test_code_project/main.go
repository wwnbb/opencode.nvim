package main

import (
	"fmt"
	"math"
	"strings"
)

type User struct {
	ID    int
	Name  string
	Email string
}

func main() {
	fmt.Println("hello world")

	user := User{
		ID:    42,
		Name:  "Jane Smith",
		Email: "jane.smith@example.com",
	}

	fmt.Printf("User: %+v\n", user)

	result := calculate(10, 5)
	fmt.Printf("Calculation result: %.2f\n", result)

	greeting := greet("OpenCode")
	fmt.Println(greeting)

	numbers := []int{1, 2, 3, 4, 5}
	sum := sumNumbers(numbers...)
	fmt.Printf("Sum: %d\n", sum)

	if isEven(4) {
		fmt.Println("4 is even")
	}
}

func calculate(a, b int) float64 {
	return math.Sqrt(float64(a*a + b*b))
}

func greet(name string) string {
	return strings.ToUpper("Hello, " + name + "!")
}

func sumNumbers(numbers ...int) int {
	total := 0
	for _, n := range numbers {
		total += n
	}
	return total
}

func isEven(n int) bool {
	return n%2 == 0
}
