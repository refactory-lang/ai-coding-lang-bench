package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const minigitDir = ".minigit"

func miniHash(data []byte) string {
	var h uint64 = 1469598103934665603
	for _, b := range data {
		h ^= uint64(b)
		h *= 1099511628211
	}
	return fmt.Sprintf("%016x", h)
}

func cmdInit() {
	if _, err := os.Stat(minigitDir); err == nil {
		fmt.Println("Repository already initialized")
		return
	}
	os.MkdirAll(filepath.Join(minigitDir, "objects"), 0755)
	os.MkdirAll(filepath.Join(minigitDir, "commits"), 0755)
	os.WriteFile(filepath.Join(minigitDir, "index"), []byte{}, 0644)
	os.WriteFile(filepath.Join(minigitDir, "HEAD"), []byte{}, 0644)
}

func cmdAdd(filename string) {
	data, err := os.ReadFile(filename)
	if err != nil {
		fmt.Println("File not found")
		os.Exit(1)
	}

	hash := miniHash(data)
	os.WriteFile(filepath.Join(minigitDir, "objects", hash), data, 0644)

	indexData, _ := os.ReadFile(filepath.Join(minigitDir, "index"))
	indexStr := string(indexData)
	lines := []string{}
	if indexStr != "" {
		lines = strings.Split(strings.TrimRight(indexStr, "\n"), "\n")
	}

	found := false
	for _, l := range lines {
		if l == filename {
			found = true
			break
		}
	}
	if !found {
		lines = append(lines, filename)
		os.WriteFile(filepath.Join(minigitDir, "index"), []byte(strings.Join(lines, "\n")+"\n"), 0644)
	}
}

func cmdCommit(message string) {
	indexData, _ := os.ReadFile(filepath.Join(minigitDir, "index"))
	indexStr := strings.TrimRight(string(indexData), "\n")
	if indexStr == "" {
		fmt.Println("Nothing to commit")
		os.Exit(1)
	}

	files := strings.Split(indexStr, "\n")
	sort.Strings(files)

	headData, _ := os.ReadFile(filepath.Join(minigitDir, "HEAD"))
	parent := strings.TrimSpace(string(headData))
	if parent == "" {
		parent = "NONE"
	}

	timestamp := time.Now().Unix()

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("parent: %s\n", parent))
	sb.WriteString(fmt.Sprintf("timestamp: %d\n", timestamp))
	sb.WriteString(fmt.Sprintf("message: %s\n", message))
	sb.WriteString("files:\n")

	for _, f := range files {
		data, _ := os.ReadFile(f)
		hash := miniHash(data)
		sb.WriteString(fmt.Sprintf("%s %s\n", f, hash))
	}

	commitContent := sb.String()
	commitHash := miniHash([]byte(commitContent))

	os.WriteFile(filepath.Join(minigitDir, "commits", commitHash), []byte(commitContent), 0644)
	os.WriteFile(filepath.Join(minigitDir, "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(minigitDir, "index"), []byte{}, 0644)

	fmt.Printf("Committed %s\n", commitHash)
}

func cmdLog() {
	headData, _ := os.ReadFile(filepath.Join(minigitDir, "HEAD"))
	current := strings.TrimSpace(string(headData))

	if current == "" {
		fmt.Println("No commits")
		return
	}

	for current != "" && current != "NONE" {
		commitData, err := os.ReadFile(filepath.Join(minigitDir, "commits", current))
		if err != nil {
			break
		}
		lines := strings.Split(string(commitData), "\n")

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

		fmt.Printf("commit %s\n", current)
		fmt.Printf("Date: %s\n", timestamp)
		fmt.Printf("Message: %s\n", message)
		fmt.Println()

		if parent == "NONE" {
			break
		}
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
