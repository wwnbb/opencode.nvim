package main

import (
	"fmt"
	"math/rand"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"golang.org/x/term"
)

// ─── Point ───────────────────────────────────────────────────────────────────

// Point represents a coordinate on the game board.
type Point struct {
	X, Y int
}

// ─── Direction ───────────────────────────────────────────────────────────────

// Direction represents a movement direction.
type Direction int

const (
	DirNone Direction = iota
	DirUp
	DirDown
	DirLeft
	DirRight
)

// ─── Game ────────────────────────────────────────────────────────────────────

// Game holds all game state.
type Game struct {
	width, height int
	snake         []Point
	food          Point
	direction     Direction
	nextDir       Direction
	score         int
	gameOver      bool
	tick          time.Duration
	baseTick      time.Duration
}

// NewGame creates and initialises a new Game.
func NewGame(width, height int) *Game {
	g := &Game{
		width:    width,
		height:   height,
		baseTick: 150 * time.Millisecond,
	}
	g.Reset()
	return g
}

// Reset reinitialises the game to its starting state.
func (g *Game) Reset() {
	cx, cy := g.width/2, g.height/2
	g.snake = []Point{
		{cx, cy},
		{cx - 1, cy},
		{cx - 2, cy},
	}
	g.direction = DirRight
	g.nextDir = DirRight
	g.score = 0
	g.gameOver = false
	g.tick = g.baseTick
	g.spawnFood()
}

// SetDirection queues a direction change, preventing reversal into self.
func (g *Game) SetDirection(d Direction) {
	if g.gameOver {
		return
	}
	switch d {
	case DirUp:
		if g.direction != DirDown {
			g.nextDir = d
		}
	case DirDown:
		if g.direction != DirUp {
			g.nextDir = d
		}
	case DirLeft:
		if g.direction != DirRight {
			g.nextDir = d
		}
	case DirRight:
		if g.direction != DirLeft {
			g.nextDir = d
		}
	}
}

// Update advances the game by one tick. Returns false when the game is over.
func (g *Game) Update() bool {
	if g.gameOver {
		return false
	}

	g.direction = g.nextDir

	// Compute new head position.
	head := g.snake[0]
	var newHead Point
	switch g.direction {
	case DirUp:
		newHead = Point{head.X, head.Y - 1}
	case DirDown:
		newHead = Point{head.X, head.Y + 1}
	case DirLeft:
		newHead = Point{head.X - 1, head.Y}
	case DirRight:
		newHead = Point{head.X + 1, head.Y}
	default:
		newHead = head
	}

	// Wall collision.
	if newHead.X < 0 || newHead.X >= g.width || newHead.Y < 0 || newHead.Y >= g.height {
		g.gameOver = true
		return false
	}

	// Self collision – check all segments except the tail (it will be removed
	// unless the snake just ate food).
	checkBody := g.snake
	if g.snake[len(g.snake)-1] != g.food {
		checkBody = checkBody[:len(checkBody)-1]
	}
	for _, p := range checkBody {
		if p == newHead {
			g.gameOver = true
			return false
		}
	}

	// Move: prepend new head.
	ate := newHead == g.food
	g.snake = append([]Point{newHead}, g.snake...)
	if !ate {
		g.snake = g.snake[:len(g.snake)-1]
	} else {
		g.score += 10
		// Speed up: 5 ms faster per food eaten, floor at 50 ms.
		newTick := g.baseTick - time.Duration(g.score/10)*5*time.Millisecond
		if newTick < 50*time.Millisecond {
			newTick = 50 * time.Millisecond
		}
		g.tick = newTick
		g.spawnFood()
	}

	return true
}

// spawnFood places food on a random unoccupied cell. If the board is full, food
// is not placed (effectively a win condition for the truly dedicated).
func (g *Game) spawnFood() {
	occupied := make(map[Point]struct{}, len(g.snake))
	for _, p := range g.snake {
		occupied[p] = struct{}{}
	}
	var free []Point
	for x := 0; x < g.width; x++ {
		for y := 0; y < g.height; y++ {
			p := Point{x, y}
			if _, ok := occupied[p]; !ok {
				free = append(free, p)
			}
		}
	}
	if len(free) > 0 {
		g.food = free[rand.Intn(len(free))]
	}
}

// ─── Terminal rendering ─────────────────────────────────────────────────────

const (
	cellEmpty     = " "
	cellSnakeBody = "■"
	cellSnakeHead = "●"
	cellFood      = "★"
	cellWall      = "█"
)

// Render draws the current game board into the provided byte buffer.
func (g *Game) Render(buf *[]byte) {
	// Hide cursor and move to top-left.
	*buf = append(*buf, "\033[?25l\033[H"...)

	// Top wall.
	*buf = append(*buf, cellWall)
	for x := 0; x < g.width; x++ {
		*buf = append(*buf, cellWall...)
	}
	*buf = append(*buf, cellWall, '\n')

	// Game rows.
	for y := 0; y < g.height; y++ {
		*buf = append(*buf, cellWall) // left wall
		for x := 0; x < g.width; x++ {
			p := Point{x, y}
			switch {
			case p == g.food:
				*buf = append(*buf, cellFood...)
			case p == g.snake[0]:
				*buf = append(*buf, cellSnakeHead...)
			default:
				isBody := false
				for i := 1; i < len(g.snake); i++ {
					if g.snake[i] == p {
						isBody = true
						break
					}
				}
				if isBody {
					*buf = append(*buf, cellSnakeBody...)
				} else {
					*buf = append(*buf, cellEmpty...)
				}
			}
		}
		*buf = append(*buf, cellWall, '\n') // right wall
	}

	// Bottom wall.
	*buf = append(*buf, cellWall)
	for x := 0; x < g.width; x++ {
		*buf = append(*buf, cellWall...)
	}
	*buf = append(*buf, cellWall, '\n')

	// Status line.
	*buf = append(*buf, fmt.Sprintf(
		"Score: %d  |  Speed: %d ms/tick  |  Q: quit\n",
		g.score, g.tick.Milliseconds())...)
}

// ─── Input handling ─────────────────────────────────────────────────────────

// keyEvent represents a single input event.
type keyEvent int

const (
	keyNone  keyEvent = iota
	keyUp
	keyDown
	keyLeft
	keyRight
	keyQuit
)

// inputReader reads keystrokes from stdin in raw mode and sends them on a
// channel. The caller must start() before use and stop() afterwards.
type inputReader struct {
	ch   chan keyEvent
	stop chan struct{}
	wg   sync.WaitGroup
}

func newInputReader() *inputReader {
	return &inputReader{
		ch:   make(chan keyEvent, 8),
		stop: make(chan struct{}),
	}
}

func (ir *inputReader) start() {
	ir.wg.Add(1)
	go ir.readLoop()
}

func (ir *inputReader) stop() {
	close(ir.stop)
	ir.wg.Wait()
	close(ir.ch)
}

func (ir *inputReader) Events() <-chan keyEvent {
	return ir.ch
}

// readLoop runs in a goroutine, reading raw terminal input one byte at a time.
// It uses a tiny state machine to reassemble ANSI escape sequences for arrow
// keys (ESC [ A / B / C / D).
func (ir *inputReader) readLoop() {
	defer ir.wg.Done()

	var b [1]byte
	// expect tracks which byte of an escape sequence we are waiting for:
	//   0 = normal (no pending escape)
	//   1 = received ESC, waiting for '['
	//   2 = received ESC '[', waiting for direction letter
	expect := 0

	for {
		n, err := os.Stdin.Read(b[:])
		if err != nil || n == 0 {
			return
		}

		switch expect {
		case 0:
			switch {
			case b[0] == 'q' || b[0] == 'Q':
				select {
				case ir.ch <- keyQuit:
				default:
				}
				return
			case b[0] == 'w' || b[0] == 'W':
				ir.trySend(keyUp)
			case b[0] == 's' || b[0] == 'S':
				ir.trySend(keyDown)
			case b[0] == 'a' || b[0] == 'A':
				ir.trySend(keyLeft)
			case b[0] == 'd' || b[0] == 'D':
				ir.trySend(keyRight)
			case b[0] == 0x1b: // ESC – likely start of arrow key sequence
				select {
				case <-ir.stop:
					return
				default:
				}
				expect = 1
			}

		case 1:
			if b[0] == '[' {
				expect = 2
			} else {
				// False alarm – standalone ESC. Re-evaluate this byte.
				expect = 0
				switch {
				case b[0] == 'q' || b[0] == 'Q':
					select {
					case ir.ch <- keyQuit:
					default:
					}
					return
				case b[0] == 'w' || b[0] == 'W':
					ir.trySend(keyUp)
				case b[0] == 's' || b[0] == 'S':
					ir.trySend(keyDown)
				case b[0] == 'a' || b[0] == 'A':
					ir.trySend(keyLeft)
				case b[0] == 'd' || b[0] == 'D':
					ir.trySend(keyRight)
				}
			}

		case 2:
			switch b[0] {
			case 'A':
				ir.trySend(keyUp)
			case 'B':
				ir.trySend(keyDown)
			case 'C':
				ir.trySend(keyRight)
			case 'D':
				ir.trySend(keyLeft)
			}
			expect = 0
		}
	}
}

// trySend is a non-blocking send on the events channel.
func (ir *inputReader) trySend(evt keyEvent) {
	select {
	case ir.ch <- evt:
	default:
	}
}

// ─── Main ────────────────────────────────────────────────────────────────────

func main() {
	rand.Seed(time.Now().UnixNano())

	const (
		boardWidth  = 20
		boardHeight = 15
	)

	// ── Raw terminal mode ──────────────────────────────────────────────────
	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: failed to set raw terminal mode: %v\n", err)
		os.Exit(1)
	}

	// Restore terminal on exit and ensure the cursor is visible.
	defer func() {
		_ = term.Restore(fd, oldState)
		fmt.Fprint(os.Stdout, "\033[?25h")
	}()

	// ── Signal handling (Ctrl+C) ──────────────────────────────────────────
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT)
	go func() {
		<-sigCh
		// Cleanup happens via the deferred restore above.
		os.Exit(0)
	}()

	// ── Input reader ──────────────────────────────────────────────────────
	ir := newInputReader()
	ir.start()
	defer ir.stop()

	// ── Game initialisation ───────────────────────────────────────────────
	game := NewGame(boardWidth, boardHeight)

	// ── Main game loop ────────────────────────────────────────────────────
	ticker := time.NewTicker(game.tick)
	defer ticker.Stop()

	// Render the initial board before the first tick.
	var buf []byte
	game.Render(&buf)
	os.Stdout.Write(buf)
	buf = buf[:0]

	running := true
	for running {
		select {
		case <-ticker.C:
			game.Update()
			if game.gameOver {
				running = false
				break
			}
			ticker.Reset(game.tick)
			game.Render(&buf)
			os.Stdout.Write(buf)
			buf = buf[:0]

		case evt := <-ir.Events():
			switch evt {
			case keyQuit:
				running = false
			case keyUp:
				game.SetDirection(DirUp)
			case keyDown:
				game.SetDirection(DirDown)
			case keyLeft:
				game.SetDirection(DirLeft)
			case keyRight:
				game.SetDirection(DirRight)
			}
		}
	}

	// ── Game Over screen ───────────────────────────────────────────────────
	// Restore cooked mode so Read blocks on a line.
	_ = term.Restore(fd, oldState)
	fmt.Fprint(os.Stdout, "\033[?25h\033[2J\033[H")

	fmt.Println()
	fmt.Println("  ╔══════════════════════╗")
	fmt.Println("  ║     G A M E   O V E R ║")
	fmt.Println("  ╠══════════════════════╣")
	fmt.Printf("  ║   Final Score: %4d   ║\n", game.score)
	fmt.Println("  ╚══════════════════════╝")
	fmt.Println()
	fmt.Println("  Press any key to exit...")

	// Wait for a single keypress (cooked mode).
	var one [1]byte
	os.Stdin.Read(one[:])
}
