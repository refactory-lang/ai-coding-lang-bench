package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func miniHash(data []byte) string {
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
	hash := miniHash(data)
	os.WriteFile(filepath.Join(".minigit", "objects", hash), data, 0644)

	// Read index and add if not present
	indexData, _ := os.ReadFile(".minigit/index")
	lines := []string{}
	for _, l := range strings.Split(string(indexData), "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}
	for _, l := range lines {
		if l == filename {
			return
		}
	}
	lines = append(lines, filename)
	os.WriteFile(".minigit/index", []byte(strings.Join(lines, "\n")+"\n"), 0644)
}

func cmdCommit(message string) {
	indexData, _ := os.ReadFile(".minigit/index")
	lines := []string{}
	for _, l := range strings.Split(string(indexData), "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) == 0 {
		fmt.Println("Nothing to commit")
		os.Exit(1)
	}

	sort.Strings(lines)

	// Build file entries
	var fileEntries []string
	for _, fname := range lines {
		data, err := os.ReadFile(fname)
		if err != nil {
			data, _ = os.ReadFile(filepath.Join(".minigit", "objects", fname))
		}
		hash := miniHash(data)
		fileEntries = append(fileEntries, fmt.Sprintf("%s %s", fname, hash))
	}

	headData, _ := os.ReadFile(".minigit/HEAD")
	parent := strings.TrimSpace(string(headData))
	if parent == "" {
		parent = "NONE"
	}

	timestamp := time.Now().Unix()

	content := fmt.Sprintf("parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n",
		parent, timestamp, message, strings.Join(fileEntries, "\n"))

	commitHash := miniHash([]byte(content))
	os.WriteFile(filepath.Join(".minigit", "commits", commitHash), []byte(content), 0644)
	os.WriteFile(".minigit/HEAD", []byte(commitHash), 0644)
	os.WriteFile(".minigit/index", []byte{}, 0644)

	fmt.Printf("Committed %s\n", commitHash)
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
		var timestamp, message, parent string
		for _, l := range lines {
			if strings.HasPrefix(l, "parent: ") {
				parent = strings.TrimPrefix(l, "parent: ")
			} else if strings.HasPrefix(l, "timestamp: ") {
				timestamp = strings.TrimPrefix(l, "timestamp: ")
			} else if strings.HasPrefix(l, "message: ") {
				message = strings.TrimPrefix(l, "message: ")
			}
		}
		fmt.Printf("commit %s\n", current)
		fmt.Printf("Date: %s\n", timestamp)
		fmt.Printf("Message: %s\n", message)
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
		fmt.Printf("Unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}
