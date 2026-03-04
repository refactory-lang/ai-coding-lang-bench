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

func miniHash(data []byte) string {
	h := uint64(1469598103934665603)
	for _, b := range data {
		h ^= uint64(b)
		h *= 1099511628211
	}
	return fmt.Sprintf("%016x", h)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: minigit <command>")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "init":
		cmdInit()
	case "add":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit add <file>")
			os.Exit(1)
		}
		cmdAdd(os.Args[2])
	case "commit":
		if len(os.Args) < 4 || os.Args[2] != "-m" {
			fmt.Fprintln(os.Stderr, "Usage: minigit commit -m \"<message>\"")
			os.Exit(1)
		}
		cmdCommit(os.Args[3])
	case "status":
		cmdStatus()
	case "log":
		cmdLog()
	case "diff":
		if len(os.Args) < 4 {
			fmt.Fprintln(os.Stderr, "Usage: minigit diff <commit1> <commit2>")
			os.Exit(1)
		}
		cmdDiff(os.Args[2], os.Args[3])
	case "checkout":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit checkout <commit_hash>")
			os.Exit(1)
		}
		cmdCheckout(os.Args[2])
	case "reset":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit reset <commit_hash>")
			os.Exit(1)
		}
		cmdReset(os.Args[2])
	case "rm":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit rm <file>")
			os.Exit(1)
		}
		cmdRm(os.Args[2])
	case "show":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit show <commit_hash>")
			os.Exit(1)
		}
		cmdShow(os.Args[2])
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
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

func cmdAdd(filename string) {
	data, err := os.ReadFile(filename)
	if err != nil {
		fmt.Println("File not found")
		os.Exit(1)
	}

	hash := miniHash(data)
	os.WriteFile(filepath.Join(".minigit", "objects", hash), data, 0644)

	// Read index and check if already present
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	lines := strings.Split(strings.TrimRight(string(indexData), "\n"), "\n")
	for _, line := range lines {
		if line == filename {
			return
		}
	}

	// Append
	f, _ := os.OpenFile(filepath.Join(".minigit", "index"), os.O_APPEND|os.O_WRONLY, 0644)
	defer f.Close()
	fmt.Fprintln(f, filename)
}

func cmdCommit(message string) {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	indexStr := strings.TrimRight(string(indexData), "\n")
	if indexStr == "" {
		fmt.Println("Nothing to commit")
		os.Exit(1)
	}

	files := strings.Split(indexStr, "\n")
	sort.Strings(files)

	// Build file entries
	var fileEntries []string
	for _, f := range files {
		data, _ := os.ReadFile(f)
		hash := miniHash(data)
		fileEntries = append(fileEntries, f+" "+hash)
	}

	// Get parent
	headData, _ := os.ReadFile(filepath.Join(".minigit", "HEAD"))
	parent := strings.TrimSpace(string(headData))
	if parent == "" {
		parent = "NONE"
	}

	timestamp := strconv.FormatInt(time.Now().Unix(), 10)

	// Build commit content
	var sb strings.Builder
	sb.WriteString("parent: " + parent + "\n")
	sb.WriteString("timestamp: " + timestamp + "\n")
	sb.WriteString("message: " + message + "\n")
	sb.WriteString("files:\n")
	for _, entry := range fileEntries {
		sb.WriteString(entry + "\n")
	}

	commitContent := sb.String()
	commitHash := miniHash([]byte(commitContent))

	os.WriteFile(filepath.Join(".minigit", "commits", commitHash), []byte(commitContent), 0644)
	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Println("Committed " + commitHash)
}

func cmdLog() {
	headData, _ := os.ReadFile(filepath.Join(".minigit", "HEAD"))
	current := strings.TrimSpace(string(headData))

	if current == "" {
		fmt.Println("No commits")
		return
	}

	for current != "" && current != "NONE" {
		commitData, err := os.ReadFile(filepath.Join(".minigit", "commits", current))
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

		fmt.Println("commit " + current)
		fmt.Println("Date: " + timestamp)
		fmt.Println("Message: " + message)
		fmt.Println()

		current = parent
	}
}

func cmdStatus() {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	indexStr := strings.TrimRight(string(indexData), "\n")
	fmt.Println("Staged files:")
	if indexStr == "" {
		fmt.Println("(none)")
	} else {
		files := strings.Split(indexStr, "\n")
		for _, f := range files {
			fmt.Println(f)
		}
	}
}

func parseCommitFiles(commitHash string) (map[string]string, error) {
	data, err := os.ReadFile(filepath.Join(".minigit", "commits", commitHash))
	if err != nil {
		return nil, err
	}
	files := make(map[string]string)
	lines := strings.Split(string(data), "\n")
	inFiles := false
	for _, line := range lines {
		if line == "files:" {
			inFiles = true
			continue
		}
		if inFiles && line != "" {
			parts := strings.SplitN(line, " ", 2)
			if len(parts) == 2 {
				files[parts[0]] = parts[1]
			}
		}
	}
	return files, nil
}

func cmdDiff(commit1, commit2 string) {
	files1, err1 := parseCommitFiles(commit1)
	if err1 != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}
	files2, err2 := parseCommitFiles(commit2)
	if err2 != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	allFiles := make(map[string]bool)
	for f := range files1 {
		allFiles[f] = true
	}
	for f := range files2 {
		allFiles[f] = true
	}

	var sorted []string
	for f := range allFiles {
		sorted = append(sorted, f)
	}
	sort.Strings(sorted)

	for _, f := range sorted {
		h1, in1 := files1[f]
		h2, in2 := files2[f]
		if in1 && !in2 {
			fmt.Println("Removed: " + f)
		} else if !in1 && in2 {
			fmt.Println("Added: " + f)
		} else if h1 != h2 {
			fmt.Println("Modified: " + f)
		}
	}
}

func cmdCheckout(commitHash string) {
	files, err := parseCommitFiles(commitHash)
	if err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	for filename, blobHash := range files {
		data, _ := os.ReadFile(filepath.Join(".minigit", "objects", blobHash))
		os.WriteFile(filename, data, 0644)
	}

	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Println("Checked out " + commitHash)
}

func cmdReset(commitHash string) {
	if _, err := os.Stat(filepath.Join(".minigit", "commits", commitHash)); err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Println("Reset to " + commitHash)
}

func cmdRm(filename string) {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	indexStr := strings.TrimRight(string(indexData), "\n")
	if indexStr == "" {
		fmt.Println("File not in index")
		os.Exit(1)
	}
	lines := strings.Split(indexStr, "\n")
	found := false
	var newLines []string
	for _, line := range lines {
		if line == filename {
			found = true
		} else {
			newLines = append(newLines, line)
		}
	}
	if !found {
		fmt.Println("File not in index")
		os.Exit(1)
	}
	newIndex := ""
	if len(newLines) > 0 {
		newIndex = strings.Join(newLines, "\n") + "\n"
	}
	os.WriteFile(filepath.Join(".minigit", "index"), []byte(newIndex), 0644)
}

func cmdShow(commitHash string) {
	data, err := os.ReadFile(filepath.Join(".minigit", "commits", commitHash))
	if err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}
	lines := strings.Split(string(data), "\n")

	var timestamp, message string
	var fileEntries []string
	inFiles := false
	for _, line := range lines {
		if strings.HasPrefix(line, "timestamp: ") {
			timestamp = strings.TrimPrefix(line, "timestamp: ")
		} else if strings.HasPrefix(line, "message: ") {
			message = strings.TrimPrefix(line, "message: ")
		} else if line == "files:" {
			inFiles = true
		} else if inFiles && line != "" {
			fileEntries = append(fileEntries, line)
		}
	}

	fmt.Println("commit " + commitHash)
	fmt.Println("Date: " + timestamp)
	fmt.Println("Message: " + message)
	fmt.Println("Files:")
	sort.Strings(fileEntries)
	for _, entry := range fileEntries {
		fmt.Println("  " + entry)
	}
}
