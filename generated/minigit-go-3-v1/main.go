package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func minihash(data []byte) string {
	var h uint64 = 1469598103934665603
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
	os.MkdirAll(filepath.Join(".minigit", "objects"), 0755)
	os.MkdirAll(filepath.Join(".minigit", "commits"), 0755)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)
	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte{}, 0644)
}

func readIndex() []string {
	data, err := os.ReadFile(filepath.Join(".minigit", "index"))
	if err != nil || len(data) == 0 {
		return nil
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	var result []string
	for _, l := range lines {
		if l != "" {
			result = append(result, l)
		}
	}
	return result
}

func writeIndex(entries []string) {
	content := ""
	if len(entries) > 0 {
		content = strings.Join(entries, "\n") + "\n"
	}
	os.WriteFile(filepath.Join(".minigit", "index"), []byte(content), 0644)
}

func cmdAdd(filename string) {
	data, err := os.ReadFile(filename)
	if err != nil {
		fmt.Println("File not found")
		os.Exit(1)
	}
	hash := minihash(data)
	os.WriteFile(filepath.Join(".minigit", "objects", hash), data, 0644)

	entries := readIndex()
	for _, e := range entries {
		if e == filename {
			return
		}
	}
	entries = append(entries, filename)
	writeIndex(entries)
}

func cmdCommit(message string) {
	entries := readIndex()
	if len(entries) == 0 {
		fmt.Println("Nothing to commit")
		os.Exit(1)
	}

	headBytes, _ := os.ReadFile(filepath.Join(".minigit", "HEAD"))
	parent := strings.TrimSpace(string(headBytes))
	if parent == "" {
		parent = "NONE"
	}

	timestamp := time.Now().Unix()

	sort.Strings(entries)

	var fileLines []string
	for _, fname := range entries {
		blobHash := blobHashForFile(fname)
		fileLines = append(fileLines, fmt.Sprintf("%s %s", fname, blobHash))
	}

	commitContent := fmt.Sprintf("parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n",
		parent, timestamp, message, strings.Join(fileLines, "\n"))

	commitHash := minihash([]byte(commitContent))
	os.WriteFile(filepath.Join(".minigit", "commits", commitHash), []byte(commitContent), 0644)
	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(commitHash), 0644)
	writeIndex(nil)

	fmt.Printf("Committed %s\n", commitHash)
}

func blobHashForFile(filename string) string {
	data, err := os.ReadFile(filename)
	if err != nil {
		// Try to find it from existing objects by re-reading the file content
		// This shouldn't happen in normal flow
		return ""
	}
	return minihash(data)
}

func cmdLog() {
	headBytes, _ := os.ReadFile(filepath.Join(".minigit", "HEAD"))
	current := strings.TrimSpace(string(headBytes))
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
		var parentHash, timestamp, message string
		for _, line := range lines {
			if strings.HasPrefix(line, "parent: ") {
				parentHash = strings.TrimPrefix(line, "parent: ")
			} else if strings.HasPrefix(line, "timestamp: ") {
				timestamp = strings.TrimPrefix(line, "timestamp: ")
			} else if strings.HasPrefix(line, "message: ") {
				message = strings.TrimPrefix(line, "message: ")
			}
		}

		fmt.Printf("commit %s\nDate: %s\nMessage: %s\n\n", current, timestamp, message)

		current = parentHash
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
