package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

func minihash(data []byte) string {
	h := uint64(1469598103934665603)
	for _, b := range data {
		h ^= uint64(b)
		h *= 1099511628211
	}
	return fmt.Sprintf("%016x", h)
}

func cmdInit() {
	if _, err := os.Stat(".minigit"); err == nil {
		fmt.Println("Repository already initialized")
		return
	}
	os.MkdirAll(".minigit/objects", 0755)
	os.MkdirAll(".minigit/commits", 0755)
	os.WriteFile(".minigit/index", []byte{}, 0644)
	os.WriteFile(".minigit/HEAD", []byte{}, 0644)
}

func cmdAdd(filename string) {
	data, err := os.ReadFile(filename)
	if err != nil {
		fmt.Println("File not found")
		os.Exit(1)
	}
	hash := minihash(data)
	os.WriteFile(filepath.Join(".minigit", "objects", hash), data, 0644)

	// Read index and add if not present
	indexData, _ := os.ReadFile(".minigit/index")
	lines := strings.Split(strings.TrimRight(string(indexData), "\n"), "\n")
	for _, l := range lines {
		if l == filename {
			return
		}
	}
	f, _ := os.OpenFile(".minigit/index", os.O_APPEND|os.O_WRONLY, 0644)
	defer f.Close()
	f.WriteString(filename + "\n")
}

func cmdCommit(message string) {
	indexData, _ := os.ReadFile(".minigit/index")
	content := strings.TrimRight(string(indexData), "\n")
	if content == "" {
		fmt.Println("Nothing to commit")
		os.Exit(1)
	}

	files := strings.Split(content, "\n")
	sort.Strings(files)

	headData, _ := os.ReadFile(".minigit/HEAD")
	parent := strings.TrimSpace(string(headData))
	if parent == "" {
		parent = "NONE"
	}

	timestamp := strconv.FormatInt(time.Now().Unix(), 10)

	var sb strings.Builder
	sb.WriteString("parent: " + parent + "\n")
	sb.WriteString("timestamp: " + timestamp + "\n")
	sb.WriteString("message: " + message + "\n")
	sb.WriteString("files:\n")
	for _, fn := range files {
		fileData, _ := os.ReadFile(fn)
		hash := minihash(fileData)
		sb.WriteString(fn + " " + hash + "\n")
	}

	commitContent := sb.String()
	commitHash := minihash([]byte(commitContent))

	os.WriteFile(filepath.Join(".minigit", "commits", commitHash), []byte(commitContent), 0644)
	os.WriteFile(".minigit/HEAD", []byte(commitHash), 0644)
	os.WriteFile(".minigit/index", []byte{}, 0644)

	fmt.Println("Committed " + commitHash)
}

func cmdLog() {
	headData, _ := os.ReadFile(".minigit/HEAD")
	current := strings.TrimSpace(string(headData))
	if current == "" {
		fmt.Println("No commits")
		return
	}

	for current != "" && current != "NONE" {
		data, err := os.ReadFile(filepath.Join(".minigit", "commits", current))
		if err != nil {
			break
		}
		lines := strings.Split(string(data), "\n")
		var timestamp, message string
		var parent string
		for _, line := range lines {
			if strings.HasPrefix(line, "parent: ") {
				parent = strings.TrimPrefix(line, "parent: ")
			} else if strings.HasPrefix(line, "timestamp: ") {
				timestamp = strings.TrimPrefix(line, "timestamp: ")
			} else if strings.HasPrefix(line, "message: ") {
				message = strings.TrimPrefix(line, "message: ")
			}
		}
		fmt.Println("commit " + current)
		fmt.Println("Date: " + timestamp)
		fmt.Println("Message: " + message)
		fmt.Println()
		current = parent
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: minigit <command>")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "init":
		cmdInit()
	case "add":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit add <file>")
			os.Exit(1)
		}
		cmdAdd(os.Args[2])
	case "commit":
		if len(os.Args) < 4 || os.Args[2] != "-m" {
			fmt.Println("Usage: minigit commit -m \"<message>\"")
			os.Exit(1)
		}
		cmdCommit(os.Args[3])
	case "log":
		cmdLog()
	default:
		fmt.Println("Unknown command: " + os.Args[1])
		os.Exit(1)
	}
}
