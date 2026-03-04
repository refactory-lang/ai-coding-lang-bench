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

func cmdStatus() {
	indexData, _ := os.ReadFile(filepath.Join(minigitDir, "index"))
	indexStr := strings.TrimRight(string(indexData), "\n")
	fmt.Println("Staged files:")
	if indexStr == "" {
		fmt.Println("(none)")
	} else {
		lines := strings.Split(indexStr, "\n")
		for _, l := range lines {
			fmt.Println(l)
		}
	}
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

func parseCommitFiles(commitHash string) (map[string]string, error) {
	data, err := os.ReadFile(filepath.Join(minigitDir, "commits", commitHash))
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
	commitPath := filepath.Join(minigitDir, "commits", commitHash)
	if _, err := os.Stat(commitPath); err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	files, _ := parseCommitFiles(commitHash)
	for filename, blobHash := range files {
		data, _ := os.ReadFile(filepath.Join(minigitDir, "objects", blobHash))
		os.WriteFile(filename, data, 0644)
	}

	os.WriteFile(filepath.Join(minigitDir, "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(minigitDir, "index"), []byte{}, 0644)

	fmt.Printf("Checked out %s\n", commitHash)
}

func cmdReset(commitHash string) {
	commitPath := filepath.Join(minigitDir, "commits", commitHash)
	if _, err := os.Stat(commitPath); err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	os.WriteFile(filepath.Join(minigitDir, "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(minigitDir, "index"), []byte{}, 0644)

	fmt.Printf("Reset to %s\n", commitHash)
}

func cmdRm(filename string) {
	indexData, _ := os.ReadFile(filepath.Join(minigitDir, "index"))
	indexStr := strings.TrimRight(string(indexData), "\n")
	if indexStr == "" {
		fmt.Println("File not in index")
		os.Exit(1)
	}
	lines := strings.Split(indexStr, "\n")
	found := false
	var newLines []string
	for _, l := range lines {
		if l == filename {
			found = true
		} else {
			newLines = append(newLines, l)
		}
	}
	if !found {
		fmt.Println("File not in index")
		os.Exit(1)
	}
	if len(newLines) == 0 {
		os.WriteFile(filepath.Join(minigitDir, "index"), []byte{}, 0644)
	} else {
		os.WriteFile(filepath.Join(minigitDir, "index"), []byte(strings.Join(newLines, "\n")+"\n"), 0644)
	}
}

func cmdShow(commitHash string) {
	commitPath := filepath.Join(minigitDir, "commits", commitHash)
	data, err := os.ReadFile(commitPath)
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

	fmt.Printf("commit %s\n", commitHash)
	fmt.Printf("Date: %s\n", timestamp)
	fmt.Printf("Message: %s\n", message)
	fmt.Println("Files:")
	sort.Strings(fileEntries)
	for _, f := range fileEntries {
		fmt.Printf("  %s\n", f)
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
	case "status":
		cmdStatus()
	case "log":
		cmdLog()
	case "diff":
		if len(os.Args) < 4 {
			fmt.Println("Usage: minigit diff <commit1> <commit2>")
			os.Exit(1)
		}
		cmdDiff(os.Args[2], os.Args[3])
	case "checkout":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit checkout <commit_hash>")
			os.Exit(1)
		}
		cmdCheckout(os.Args[2])
	case "reset":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit reset <commit_hash>")
			os.Exit(1)
		}
		cmdReset(os.Args[2])
	case "rm":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit rm <file>")
			os.Exit(1)
		}
		cmdRm(os.Args[2])
	case "show":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit show <commit_hash>")
			os.Exit(1)
		}
		cmdShow(os.Args[2])
	default:
		fmt.Printf("Unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}
