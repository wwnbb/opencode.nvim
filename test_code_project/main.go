package main

import (
	"fmt"
	"math"
	"strings"
)

const (
	defaultUserID    = 40
	defaultUserName  = "Jane Smith"
	defaultUserEmail = "jane.smith@example.com"

	defaultGreetingName = "OpenCode"
	defaultEvenNumber   = 4
)

type User struct {
	ID    int
	Name  string
	Email string
}

func (u User) Summary() string {
	return fmt.Sprintf("%s <%s> [id=%d]", u.Name, u.Email, u.ID)
}

func main() {
	printWelcome()

	user := newUser(defaultUserID, defaultUserName, defaultUserEmail)
	printUser(user)
	printCalculationResult(10, 5)
	printGreetingText(defaultGreetingName)
	printSum([]int{1, 2, 3, 4, 5})
	printEvenStatus(defaultEvenNumber)
}

func newUser(id int, name, email string) User {
	return User{
		ID:    id,
		Name:  name,
		Email: email,
	}
}

func printWelcome() {
	fmt.Println("hello world")
}

func printUser(user User) {
	fmt.Printf("User: %s\n", user.Summary())
}

func printCalculationResult(a, b int) {
	fmt.Printf("Calculation result: %.2f\n", calculateHypotenuse(a, b))
}

func calculateHypotenuse(a, b int) float64 {
	return math.Hypot(float64(a), float64(b))
}

func printGreetingText(name string) {
	fmt.Println(buildGreeting(name))
}

func buildGreeting(name string) string {
	return strings.ToUpper(fmt.Sprintf("Hello, %s!", name))
}

func printSum(numbers []int) {
	fmt.Printf("Sum: %d\n", sum(numbers...))
}

func sum(numbers ...int) int {
	total := 0
	for _, n := range numbers {
		total += n
	}
	return total
}

func printEvenStatus(n int) {
	if !isEven(n) {
		return
	}

	fmt.Printf("%d is even\n", n)
}

func isEven(n int) bool {
	return n%2 == 0
}
