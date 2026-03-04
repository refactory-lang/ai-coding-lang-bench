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

	hash := minihash(data)
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
	content := strings.TrimRight(string(indexData), "\n")
	if content == "" {
		fmt.Println("Nothing to commit")
		os.Exit(1)
	}

	files := strings.Split(content, "\n")
	sort.Strings(files)

	headData, _ := os.ReadFile(filepath.Join(".minigit", "HEAD"))
	parent := strings.TrimSpace(string(headData))
	if parent == "" {
		parent = "NONE"
	}

	timestamp := time.Now().Unix()

	var sb strings.Builder
	fmt.Fprintf(&sb, "parent: %s\n", parent)
	fmt.Fprintf(&sb, "timestamp: %d\n", timestamp)
	fmt.Fprintf(&sb, "message: %s\n", message)
	fmt.Fprintln(&sb, "files:")

	for _, fname := range files {
		data, _ := os.ReadFile(fname)
		hash := minihash(data)
		fmt.Fprintf(&sb, "%s %s\n", fname, hash)
	}

	commitContent := sb.String()
	commitHash := minihash([]byte(commitContent))

	os.WriteFile(filepath.Join(".minigit", "commits", commitHash), []byte(commitContent), 0644)
	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Printf("Committed %s\n", commitHash)
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
		var parent, timestamp, message string
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

		current = parent
	}
}

func cmdStatus() {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	content := strings.TrimRight(string(indexData), "\n")
	fmt.Println("Staged files:")
	if content == "" {
		fmt.Println("(none)")
	} else {
		lines := strings.Split(content, "\n")
		for _, line := range lines {
			fmt.Println(line)
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

	sorted := make([]string, 0, len(allFiles))
	for f := range allFiles {
		sorted = append(sorted, f)
	}
	sort.Strings(sorted)

	for _, f := range sorted {
		h1, in1 := files1[f]
		h2, in2 := files2[f]
		if in1 && !in2 {
			fmt.Printf("Removed: %s\n", f)
		} else if !in1 && in2 {
			fmt.Printf("Added: %s\n", f)
		} else if h1 != h2 {
			fmt.Printf("Modified: %s\n", f)
		}
	}
}

func cmdCheckout(commitHash string) {
	files, err := parseCommitFiles(commitHash)
	if err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	for fname, blobHash := range files {
		data, _ := os.ReadFile(filepath.Join(".minigit", "objects", blobHash))
		os.WriteFile(fname, data, 0644)
	}

	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Printf("Checked out %s\n", commitHash)
}

func cmdReset(commitHash string) {
	if _, err := os.Stat(filepath.Join(".minigit", "commits", commitHash)); err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Printf("Reset to %s\n", commitHash)
}

func cmdRm(filename string) {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	content := strings.TrimRight(string(indexData), "\n")
	if content == "" {
		fmt.Println("File not in index")
		os.Exit(1)
	}
	lines := strings.Split(content, "\n")
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
	newContent := ""
	if len(newLines) > 0 {
		newContent = strings.Join(newLines, "\n") + "\n"
	}
	os.WriteFile(filepath.Join(".minigit", "index"), []byte(newContent), 0644)
}

func cmdShow(commitHash string) {
	data, err := os.ReadFile(filepath.Join(".minigit", "commits", commitHash))
	if err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	lines := strings.Split(string(data), "\n")
	var timestamp, message string
	var fileLines []string
	inFiles := false
	for _, line := range lines {
		if strings.HasPrefix(line, "timestamp: ") {
			timestamp = strings.TrimPrefix(line, "timestamp: ")
		} else if strings.HasPrefix(line, "message: ") {
			message = strings.TrimPrefix(line, "message: ")
		} else if line == "files:" {
			inFiles = true
		} else if inFiles && line != "" {
			fileLines = append(fileLines, line)
		}
	}

	fmt.Printf("commit %s\n", commitHash)
	fmt.Printf("Date: %s\n", timestamp)
	fmt.Printf("Message: %s\n", message)
	fmt.Println("Files:")
	sort.Strings(fileLines)
	for _, fl := range fileLines {
		fmt.Printf("  %s\n", fl)
	}
}
